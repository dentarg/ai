#!/usr/bin/env ruby
# Tiny web app that lists running Docker containers and links to their
# host-published ports. Auto-refresh off by default (set REFRESH=<seconds>).
# Stdlib only.

require "socket"
require "json"
require "cgi"
require "open3"

PORT             = (ENV["PORT"] || 4567).to_i
BIND             = ENV["BIND"] || "127.0.0.1"
REFRESH_SECONDS  = (ENV["REFRESH"] || 0).to_i

Container = Struct.new(
  :id,
  :name,
  :image,
  :status,
  :ports,
  :labels,
  :branch,
  :agent,
  keyword_init: true,
)

AGENT_NAMES = {
  "claude" => "Claude",
  "codex" => "Codex",
  "copilot" => "Copilot",
  "gemini" => "Gemini",
}.freeze

AGENT_CLASSES = {
  "Claude" => "agent-claude",
  "Codex" => "agent-codex",
  "Copilot" => "agent-copilot",
  "Gemini" => "agent-gemini",
}.freeze

# Podman emits Ports as an array of objects like:
#   {"host_ip": "0.0.0.0", "container_port": 80, "host_port": 8080,
#    "range": 1, "protocol": "tcp"}
# `range` covers contiguous mappings (e.g. 8000-8002 -> 80-82) so we expand it.
def parse_ports(ports)
  return [] if ports.nil? || ports.empty?

  seen = {}
  ports.each do |p|
    next unless p["protocol"] == "tcp" # only TCP is browsable
    range = (p["range"] || 1).to_i
    range = 1 if range < 1
    range.times do |i|
      hport = p["host_port"].to_i + i
      next if hport <= 0
      cport = p["container_port"].to_i + i
      ip    = p["host_ip"].to_s
      ip    = "0.0.0.0" if ip.empty?
      next if seen[hport]
      seen[hport] = { host_port: hport, container_port: cport, ip: ip }
    end
  end
  seen.values.sort_by { |p| p[:host_port] }
end

def resolve_cwd(cwd)
  return if cwd.nil? || cwd.empty?

  path =
    if cwd == "~"
      Dir.home
    elsif cwd.start_with?("~/")
      File.join(Dir.home, cwd.delete_prefix("~/"))
    else
      cwd
    end

  File.expand_path(path)
rescue ArgumentError
  nil
end

def current_git_branch(path)
  return unless File.directory?(path)

  branch, status = Open3.capture2(
    "git",
    "-C",
    path,
    "symbolic-ref",
    "--quiet",
    "--short",
    "HEAD",
    err: File::NULL,
  )
  return unless status.success?

  branch = branch.strip
  branch unless branch.empty?
rescue SystemCallError
  nil
end

def attach_git_branches(containers)
  containers.group_by { |container| resolve_cwd(container.labels["cwd"]) }
    .each do |path, matching_containers|
      next if path.nil?

      branch = current_git_branch(path)
      matching_containers.each { |container| container.branch = branch }
    end
end

def agent_from_command(command)
  executable = File.basename(command.split.first.to_s).downcase
  return "Claude" if executable == "claude"
  return "Codex" if executable == "codex"
  return "Gemini" if executable == "gemini"
  return "Copilot" if executable == "copilot"

  return "Codex" if command.include?("@openai/codex")
  return "Gemini" if command.include?("@google/gemini-cli")
  return "Copilot" if command.include?("@github/copilot")
end

def running_agents(container_id)
  output, status = Open3.capture2(
    "podman",
    "top",
    container_id,
    "args",
    err: File::NULL,
  )
  return [] unless status.success?

  output.lines.drop(1).filter_map { |command| agent_from_command(command) }.uniq
rescue SystemCallError
  []
end

def attach_agents(containers)
  containers.each do |container|
    label = container.labels["agent"].to_s.downcase
    container.agent = AGENT_NAMES[label]
    next if container.agent

    agents = running_agents(container.id)
    container.agent = agents.join(" + ") unless agents.empty?
  end
end

def fetch_containers
  out = `podman ps --format json 2>&1`
  unless $?.success?
    return [:error, out.strip]
  end

  list = JSON.parse(out)
  containers = list.map do |j|
    name = Array(j["Names"]).first || j["Name"] || j["Id"].to_s[0, 12]
    Container.new(
      id:     j["Id"].to_s[0, 12],
      name:   name,
      image:  j["Image"],
      status: j["Status"] || j["State"],
      ports:  parse_ports(j["Ports"]),
      labels: j["Labels"] || {},
    )
  end
  attach_git_branches(containers)
  attach_agents(containers)
  [:ok, containers]
end

def render_table(containers)
  rows = containers.map { |container| render_row(container) }.join("\n")
  <<~HTML
    <table>
      <thead>
        <tr>
          <th aria-sort="none"><button type="button" data-sort-type="text">Name</button></th>
          <th aria-sort="none"><button type="button" data-sort-type="text">Status</button></th>
          <th aria-sort="none"><button type="button" data-sort-type="text">ID</button></th>
          <th aria-sort="none"><button type="button" data-sort-type="text">Cwd</button></th>
          <th aria-sort="none"><button type="button" data-sort-type="text">Agent</button></th>
          <th aria-sort="none"><button type="button" data-sort-type="number">Ports</button></th>
        </tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
  HTML
end

def container_count_label(status, data)
  return "Container count unavailable" if status == :error

  count = data.length
  noun = count == 1 ? "container" : "containers"
  "#{count} #{noun} running"
end

def render_html
  status, data = fetch_containers
  count_label = container_count_label(status, data)
  refresh_label = REFRESH_SECONDS > 0 ? "Refreshing every #{REFRESH_SECONDS}s" : "Auto-refresh off"
  rendered_at = Time.now.strftime("%H:%M:%S")
  body =
    if status == :error
      "<p class=\"error\">docker error: #{CGI.escapeHTML(data)}</p>"
    elsif data.empty?
      "<p class=\"empty\">No running containers.</p>"
    else
      render_table(data)
    end

  <<~HTML
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      #{REFRESH_SECONDS > 0 ? %(<meta http-equiv="refresh" content="#{REFRESH_SECONDS}">) : ""}
      <title>Running containers</title>
      <style>
        :root {
          --bg: #fff;
          --fg: #222;
          --muted: #666;
          --faint: #999;
          --border: #eee;
          --th-bg: #fafafa;
          --row-hover: #fcfcfc;
          --link: #0366d6;
          --port-bg: #eef4ff;
          --branch-bg: #e8f5ee;
          --branch-fg: #18794e;
          --main-branch-bg: #f1f3f5;
          --main-branch-fg: #6b7280;
          --agent-bg: #f1f3f5;
          --agent-fg: #4b5563;
          --claude-bg: #fff0e6;
          --claude-fg: #a4470d;
          --codex-bg: #e8f5ee;
          --codex-fg: #18794e;
          --copilot-bg: #f3e8ff;
          --copilot-fg: #7e22ce;
          --gemini-bg: #e8f0ff;
          --gemini-fg: #2457a6;
          --error: #b00;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #22252a;
            --fg: #c9ccd1;
            --muted: #8b9098;
            --faint: #6a6e75;
            --border: #2f333a;
            --th-bg: #282c32;
            --row-hover: #2a2e34;
            --link: #79b8ff;
            --port-bg: #2a3142;
            --branch-bg: #173b2b;
            --branch-fg: #7ee2a8;
            --main-branch-bg: #30343b;
            --main-branch-fg: #9298a1;
            --agent-bg: #30343b;
            --agent-fg: #aeb4be;
            --claude-bg: #4a2b1b;
            --claude-fg: #f0a56b;
            --codex-bg: #173b2b;
            --codex-fg: #7ee2a8;
            --copilot-bg: #3b2452;
            --copilot-fg: #d8a7ff;
            --gemini-bg: #203457;
            --gemini-fg: #8db8ff;
            --error: #ff8a8a;
          }
        }
        body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; background: var(--bg); color: var(--fg); }
        h1 { margin: 0 0 0.25rem; font-size: 1.25rem; }
        .meta { color: var(--muted); font-size: 0.85rem; margin-bottom: 1rem; }
        table { border-collapse: collapse; width: 100%; }
        th, td { text-align: left; padding: 0.4rem 0.75rem; border-bottom: 1px solid var(--border); vertical-align: top; }
        th { background: var(--th-bg); font-weight: 600; }
        th button {
          padding: 0;
          border: 0;
          color: inherit;
          background: transparent;
          font: inherit;
          cursor: pointer;
        }
        th button::after { content: " ↕"; color: var(--faint); }
        th[aria-sort="ascending"] button::after { content: " ↑"; color: var(--fg); }
        th[aria-sort="descending"] button::after { content: " ↓"; color: var(--fg); }
        th button:focus-visible { outline: 2px solid var(--link); outline-offset: 3px; }
        tr:hover td { background: var(--row-hover); }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        .port { display: block; width: fit-content; margin: 0 0 0.25rem; padding: 0.1rem 0.4rem; background: var(--port-bg); border-radius: 3px; font-size: 0.85rem; }
        .image {
          display: block;
          margin-top: 0.2rem;
          color: var(--faint);
          font-size: 0.75rem;
        }
        .agent {
          display: inline-block;
          width: fit-content;
          padding: 0.08rem 0.35rem;
          color: var(--agent-fg);
          background: var(--agent-bg);
          border-radius: 3px;
          font-size: 0.72rem;
          font-weight: 600;
        }
        .agent-claude { color: var(--claude-fg); background: var(--claude-bg); }
        .agent-codex { color: var(--codex-fg); background: var(--codex-bg); }
        .agent-copilot { color: var(--copilot-fg); background: var(--copilot-bg); }
        .agent-gemini { color: var(--gemini-fg); background: var(--gemini-bg); }
        .cwd { white-space: nowrap; }
        .cwd-parent { color: var(--muted); }
        .cwd-name { color: var(--fg); font-weight: 700; }
        .branch {
          display: block;
          width: fit-content;
          margin-top: 0.3rem;
          padding: 0.1rem 0.4rem;
          color: var(--branch-fg);
          background: var(--branch-bg);
          border-radius: 999px;
          font-size: 0.78rem;
          font-weight: 600;
        }
        .branch-main {
          color: var(--main-branch-fg);
          background: var(--main-branch-bg);
          font-weight: 500;
        }
        .no-ports { color: var(--faint); font-size: 0.85rem; }
        .error { color: var(--error); }
        .empty { color: var(--muted); }
        code { font-family: ui-monospace, Menlo, monospace; font-size: 0.85rem; }
      </style>
    </head>
    <body>
      <h1>Running containers</h1>
      <div class="meta">#{count_label} · #{refresh_label} · #{rendered_at}</div>
      #{body}
      <script>
        const collator = new Intl.Collator(undefined, {
          numeric: true,
          sensitivity: "base",
        });

        document.querySelectorAll("th button[data-sort-type]").forEach((button) => {
          button.addEventListener("click", () => {
            const header = button.closest("th");
            const table = header.closest("table");
            const headers = Array.from(header.parentElement.children);
            const column = headers.indexOf(header);
            const ascending = header.getAttribute("aria-sort") !== "ascending";
            const rows = Array.from(table.tBodies[0].rows);

            rows.sort((left, right) => {
              const leftValue = left.cells[column].dataset.sortValue || "";
              const rightValue = right.cells[column].dataset.sortValue || "";
              if (!leftValue || !rightValue) {
                if (!leftValue && !rightValue) return 0;
                return leftValue ? -1 : 1;
              }

              const comparison = button.dataset.sortType === "number"
                ? Number(leftValue) - Number(rightValue)
                : collator.compare(leftValue, rightValue);
              return ascending ? comparison : -comparison;
            });

            headers.forEach((item) => item.setAttribute("aria-sort", "none"));
            header.setAttribute("aria-sort", ascending ? "ascending" : "descending");
            rows.forEach((row) => table.tBodies[0].appendChild(row));
          });
        });
      </script>
    </body>
    </html>
  HTML
end

def render_cwd(labels, branch)
  cwd = labels && labels["cwd"]
  return "<span class=\"no-ports\">—</span>" if cwd.nil? || cwd.empty?

  cwd_name = File.basename(cwd)
  cwd_parent = cwd.delete_suffix(cwd_name)
  html = '<code class="cwd">'
  html += "<span class=\"cwd-parent\">#{CGI.escapeHTML(cwd_parent)}</span>"
  html += "<span class=\"cwd-name\">#{CGI.escapeHTML(cwd_name)}</span></code>"
  if branch && !branch.empty?
    branch_class = branch == "main" ? "branch branch-main" : "branch"
    html += "<code class=\"#{branch_class}\">#{CGI.escapeHTML(branch)}</code>"
  end
  html
end

def render_agent(agent)
  return "<span class=\"no-ports\">—</span>" if agent.nil? || agent.empty?

  css_class = ["agent", AGENT_CLASSES[agent]].compact.join(" ")
  "<span class=\"#{css_class}\">#{CGI.escapeHTML(agent)}</span>"
end

def render_row(c)
  cwd = c.labels["cwd"].to_s
  first_port = c.ports.first
  ports_html =
    if c.ports.empty?
      "<span class=\"no-ports\">—</span>"
    else
      c.ports.map { |p|
        url = "http://localhost:#{p[:host_port]}"
        "<a class=\"port\" href=\"#{url}\" target=\"_blank\">#{p[:host_port]} → #{p[:container_port]}</a>"
      }.join(" ")
    end

  <<~ROW
    <tr>
      <td data-sort-value="#{CGI.escapeHTML(c.name)}">
        <code>#{CGI.escapeHTML(c.name)}</code>
        <span class="image">#{CGI.escapeHTML(c.image)}</span>
      </td>
      <td data-sort-value="#{CGI.escapeHTML(c.status)}">#{CGI.escapeHTML(c.status)}</td>
      <td data-sort-value="#{CGI.escapeHTML(c.id)}"><code>#{CGI.escapeHTML(c.id)}</code></td>
      <td data-sort-value="#{CGI.escapeHTML(cwd)}">#{render_cwd(c.labels, c.branch)}</td>
      <td data-sort-value="#{CGI.escapeHTML(c.agent.to_s)}">#{render_agent(c.agent)}</td>
      <td data-sort-value="#{first_port && first_port[:host_port]}">#{ports_html}</td>
    </tr>
  ROW
end

def handle(client)
  request_line = client.gets
  return if request_line.nil?
  # Drain headers
  while (line = client.gets) && line != "\r\n"
  end

  path = request_line.split(" ")[1] || "/"
  if path == "/" || path.start_with?("/?")
    body = render_html
    client.write "HTTP/1.1 200 OK\r\n"
    client.write "Content-Type: text/html; charset=utf-8\r\n"
    client.write "Content-Length: #{body.bytesize}\r\n"
    client.write "Connection: close\r\n\r\n"
    client.write body
  else
    client.write "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  end
rescue => e
  warn "request error: #{e.class}: #{e.message}"
ensure
  client.close rescue nil
end

def run_server
  server = TCPServer.new(BIND, PORT)
  puts "container-ports listening on http://#{BIND}:#{PORT} (refresh #{REFRESH_SECONDS > 0 ? "#{REFRESH_SECONDS}s" : "off"})"

  trap("INT")  { puts "\nshutting down"; exit 0 }
  trap("TERM") { exit 0 }

  loop do
    client = server.accept
    Thread.new(client) { |connection| handle(connection) }
  end
end

run_server if $PROGRAM_NAME == __FILE__
