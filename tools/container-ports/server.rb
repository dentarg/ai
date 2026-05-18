#!/usr/bin/env ruby
# Tiny web app that lists running Docker containers and links to their
# host-published ports. Auto-refreshes on an interval. Stdlib only.

require "socket"
require "json"
require "cgi"

PORT             = (ENV["PORT"] || 4567).to_i
BIND             = ENV["BIND"] || "127.0.0.1"
REFRESH_SECONDS  = (ENV["REFRESH"] || 5).to_i

Container = Struct.new(:id, :name, :image, :status, :ports, keyword_init: true)

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
    )
  end
  [:ok, containers]
end

def render_html
  status, data = fetch_containers
  body =
    if status == :error
      "<p class=\"error\">docker error: #{CGI.escapeHTML(data)}</p>"
    elsif data.empty?
      "<p class=\"empty\">No running containers.</p>"
    else
      rows = data.map { |c| render_row(c) }.join("\n")
      <<~HTML
        <table>
          <thead>
            <tr><th>Name</th><th>Image</th><th>Status</th><th>ID</th><th>Ports</th></tr>
          </thead>
          <tbody>
            #{rows}
          </tbody>
        </table>
      HTML
    end

  <<~HTML
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta http-equiv="refresh" content="#{REFRESH_SECONDS}">
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
            --error: #ff8a8a;
          }
        }
        body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; background: var(--bg); color: var(--fg); }
        h1 { margin: 0 0 0.25rem; font-size: 1.25rem; }
        .meta { color: var(--muted); font-size: 0.85rem; margin-bottom: 1rem; }
        table { border-collapse: collapse; width: 100%; }
        th, td { text-align: left; padding: 0.4rem 0.75rem; border-bottom: 1px solid var(--border); vertical-align: top; }
        th { background: var(--th-bg); font-weight: 600; }
        tr:hover td { background: var(--row-hover); }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        .port { display: inline-block; margin: 0 0.5rem 0.25rem 0; padding: 0.1rem 0.4rem; background: var(--port-bg); border-radius: 3px; font-size: 0.85rem; }
        .no-ports { color: var(--faint); font-size: 0.85rem; }
        .error { color: var(--error); }
        .empty { color: var(--muted); }
        code { font-family: ui-monospace, Menlo, monospace; font-size: 0.85rem; }
      </style>
    </head>
    <body>
      <h1>Running containers</h1>
      <div class="meta">Refreshing every #{REFRESH_SECONDS}s · #{Time.now.strftime('%H:%M:%S')}</div>
      #{body}
    </body>
    </html>
  HTML
end

def render_row(c)
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
      <td><code>#{CGI.escapeHTML(c.name)}</code></td>
      <td>#{CGI.escapeHTML(c.image)}</td>
      <td>#{CGI.escapeHTML(c.status)}</td>
      <td><code>#{CGI.escapeHTML(c.id)}</code></td>
      <td>#{ports_html}</td>
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

server = TCPServer.new(BIND, PORT)
puts "container-ports listening on http://#{BIND}:#{PORT} (refresh #{REFRESH_SECONDS}s)"

trap("INT")  { puts "\nshutting down"; exit 0 }
trap("TERM") { exit 0 }

loop do
  client = server.accept
  Thread.new(client) { |c| handle(c) }
end
