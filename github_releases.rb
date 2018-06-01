#!/usr/bin/env ruby
require 'graphql/client'
require 'graphql/client/http'
require 'json'
require 'pp'
require 'slop'

# The GraphQL gem _forces_ us to make the client a constant:
# https://github.com/github/graphql-client/blob/master/guides/dynamic-query-error.md

module GithubQueries
  GITHUB_API_TOKEN = ENV['GITHUB_API_TOKEN']
  unless GITHUB_API_TOKEN
    raise "You must set a GITHUB_API_TOKEN variable to query github"
  end

  HTTP = GraphQL::Client::HTTP.new("https://api.github.com/graphql") do
    def headers(context)
      {"Authorization" => "token #{GITHUB_API_TOKEN}"}
    end
  end

  unless File.exist?("github_schema.json") && ENV['REPLACE_GITHUB_SCHEMA'].to_s.downcase != 'true'
    puts "Querying and saving github graphql schema data to github_schema.json"
    GraphQL::Client.dump_schema(HTTP, "github_schema.json")
  end

  SCHEMA = GraphQL::Client.load_schema("github_schema.json")

  CLIENT = GraphQL::Client.new(schema: SCHEMA, execute: HTTP)

  RELEASE_QUERY = CLIENT.parse <<~'GRAPHQL'
    query($owner: String!, $repo: String!, $cursor: String) {
      repository(owner:$owner, name:$repo) {
        releases(first:100, after: $cursor) {
          totalCount
          pageInfo {
            endCursor
          }
          edges {
            node {
              isDraft
              isPrerelease
              author {
                login
                email
              }
              createdAt
              name
              tag {
                name
                prefix
              }
              createdAt
              updatedAt
              publishedAt
              url
            }
          }
        }
      }
    }
    GRAPHQL

  class NoResponseError < StandardError
    def initialize(msg)
      super(msg)
    end
  end

  def self.nested_api_query(query, variables, *properties)
    response = CLIENT.query(query, variables: variables)
    unless response.errors.empty?
      raise response.errors.inspect
    end
    nested_data = response.data.to_h.dig(*properties.map {|p| p.to_s})
    unless nested_data
      $stderr.puts "can't find nested field #{properties.join(',')} in query with params: #{variables.to_s}"
      $stderr.puts "response was: #{response.data.to_h.to_s}"
      raise NoResponseError.new("No response entry for nested keys #{properties.join(',')} query params: #{variables.to_s}")
    end
    nested_data
  end

  def self.paginated_query(query, variables, max_results, *properties)
    response = self.nested_api_query(query, variables, *properties)

    end_cursor = response["pageInfo"]["endCursor"]
    results = response["edges"].map {|e| e["node"]}

    while end_cursor != nil && results.count < max_results
      response = self.nested_api_query(query, variables.dup.merge({cursor: end_cursor}), *properties)
      end_cursor = response["pageInfo"]["endCursor"]
      results.concat(response["edges"].map {|e| e["node"]})
    end

    results.take(max_results)
  end

  def self.releases(owner, repo, max_results)
    self.paginated_query(RELEASE_QUERY, {owner: owner, repo: repo}, max_results, :repository, :releases)
  end

end

if __FILE__ == $0
  opts = Slop.parse do |o|
    o.string "-o", "--owner", required: true
    o.string "-r", "--repository", required: true
    o.integer "-l", "--limit", default: 0
    o.on '-h', '--help' do
      puts o
      exit
    end
  end

  limit = opts[:limit] == 0 ? 999999999 : opts[:limit]
  puts JSON.pretty_generate(GithubQueries::releases(opts[:owner],opts[:repository],limit))
end
