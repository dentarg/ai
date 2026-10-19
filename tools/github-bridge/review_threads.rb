require "json"
require "timeout"
require_relative "errors"

module GitHubBridge
  class ReviewThreads
    LIST = <<~GRAPHQL.freeze
      query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100, after: $cursor) {
              nodes {
                id isResolved isOutdated path line
                comments(first: 1) { nodes { databaseId body url author { login } } }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }
    GRAPHQL
    LOOKUP = <<~GRAPHQL.freeze
      query($id: ID!) {
        node(id: $id) {
          ... on PullRequestReviewThread {
            id
            pullRequest { number repository { nameWithOwner } }
          }
        }
      }
    GRAPHQL
    REPLY = <<~GRAPHQL.freeze
      mutation($id: ID!, $body: String!) {
        addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $id, body: $body}) {
          comment { id url body }
        }
      }
    GRAPHQL
    RESOLVE = <<~GRAPHQL.freeze
      mutation($id: ID!) {
        resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } }
      }
    GRAPHQL

    def initialize(gh:, runner:, env:, directory:)
      @gh, @runner, @env, @directory = gh, runner, env, directory
    end

    def call(request)
      @bytes = 0
      Timeout.timeout(60) do
        if request.fetch("operation") == "pr-review-threads"
          list(request)
        else
          mutate(request)
        end
      end
    end

    private

    def query(document, variables, stage:)
      output = @runner.call(
        [@gh, "api", "--hostname", "github.com", "graphql", "--input", "-"],
        env: @env, directory: @directory,
        input: JSON.generate("query" => document, "variables" => variables),
      )
      @bytes += output.bytesize
      raise "review thread output limit exceeded" if @bytes > 2 * 1024 * 1024

      response = JSON.parse(output)
      raise RequestError.graphql(response["errors"], stage: stage) if response["errors"] && !response["errors"].empty?

      response.fetch("data")
    rescue CommandError => error
      raise RequestError.command(error, stage: stage)
    end

    def list(request)
      owner, name = request.fetch("repository").split("/", 2)
      variables = { "owner" => owner, "name" => name, "number" => request.fetch("number"), "cursor" => nil }
      records, cursors = [], []
      loop do
        connection = query(LIST, variables, stage: "review_thread_list").fetch("repository").fetch("pullRequest").fetch("reviewThreads")
        records.concat(connection.fetch("nodes"))
        page = connection.fetch("pageInfo")
        break unless page.fetch("hasNextPage")

        cursor = page.fetch("endCursor")
        raise "invalid review thread pagination" unless cursor.is_a?(String) && !cursor.empty? && !cursors.include?(cursor)

        cursors << cursor
        variables["cursor"] = cursor
      end
      records
    end

    def mutate(request)
      variables = { "id" => request.fetch("thread_id") }
      thread = query(LOOKUP, variables, stage: "review_thread_lookup").fetch("node")
      pr = thread && thread["pullRequest"]
      unless pr && pr.fetch("number") == request.fetch("number") &&
          pr.fetch("repository").fetch("nameWithOwner").casecmp?(request.fetch("repository"))
        raise RequestError.new(stage: "review_thread_lookup", error_message: "thread does not belong to the requested pull request")
      end

      case request.fetch("operation")
      when "pr-review-reply"
        query(REPLY, variables.merge("body" => request.fetch("body")), stage: "review_thread_reply").fetch("addPullRequestReviewThreadReply").fetch("comment")
      when "pr-review-resolve"
        query(RESOLVE, variables, stage: "review_thread_resolve").fetch("resolveReviewThread").fetch("thread")
      else
        raise "unsupported review thread operation"
      end
    end
  end
end
