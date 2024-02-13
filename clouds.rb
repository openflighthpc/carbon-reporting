# frozen_string_literal: true

require 'yaml'
require 'faraday_middleware'
require 'json'

args = Hash[ARGV.join(' ').scan(/--?([^=\s]+)(?:=(\S+))?/)]

BOAVIZTA_URL = ENV['BOAVIZTA_ENDPOINT_URL']

conn = Faraday.new(BOAVIZTA_URL)

response = conn.get('/v1/cloud/instance/all_providers') do |req|
  #
end

puts response.body
