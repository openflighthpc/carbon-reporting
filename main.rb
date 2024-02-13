# frozen_string_literal: true

require 'yaml'
require 'faraday_middleware'
require 'json'
require 'fileutils'

args = Hash[ARGV.join(' ').scan(/--?([^=\s]+)(?:=(\S+))?/)]

BOAVIZTA_URL = ENV['BOAVIZTA_ENDPOINT_URL']
PROVIDER = args['provider']
SERVER = args['server']
raise "No provider given" unless PROVIDER
raise 'No server given' unless args['server']


def boavizta
  @boavizta ||= Faraday.new(BOAVIZTA_URL)
end

def read_yaml(path)
  YAML.load_file(path)
rescue Errno::ENOENT
  raise "File doesn't exist"
end

def print_usage!(server, count: 1)
  lifetime = (server['usage']['hours_life_time'] / 24.0 / 365).ceil
  puts "Lifetime: #{lifetime} years"

  response = boavizta.post('/v1/server/') do |req|
    req.headers[:content_type] = 'application/json'
    req.params[:verbose] = false
    req.body = JSON.generate(server)
  end

  data = JSON.parse(response.body)

  manufacture = data['impacts']['gwp']['embedded']['value'] * count
  usage = data['impacts']['gwp']['use']['value']* count

  puts "Cluster manufacture cost: #{manufacture} kgCO2eq"
  puts "Cluster usage cost: #{usage} kgCO2eq"

  total = manufacture + usage
  per_year = total / lifetime
  puts "Amortized cost: #{per_year} kgCO2eq per year"
end

def list_instance_types(provider)
  response = boavizta.get('/v1/cloud/instance/all_instance_data') do |req|
    req.params[:provider] = provider
  end

  JSON.parse(response.body)['data']
end

def query_cloud_cost(instance_type)
  response = boavizta.get('/v1/cloud/instance') do |req|
    req.params[:provider] = PROVIDER
    req.params[:instance_type] = instance_type.to_s
    req.params[:verbose] = false
    req.params['criteria'] = 'gwp'
    req.params['duration'] = 8760
  end

  gwp = JSON.parse(response.body)['impacts']['gwp']
  gwp['embedded']['value'] + gwp['use']['value']
rescue JSON::ParserError => e
  puts "failed to grab carbon cost for '#{instance_type}'"
  return nil
end

server = read_yaml(SERVER)
server_count = args['server-count']&.to_i || 1

puts "On prem usage:\n---"
print_usage!(server, count: server_count)
puts

server['usage']['usage_location'] = 'SWE'
server['usage']['hours_life_time'] = 70_080
puts "The same system, but in Sweden over 8 years:\n---"
print_usage!(server, count: server_count)
puts

vcpus = 
  (server.dig('configuration', 'cpu', 'core_units') || 1) *
  (server.dig('configuration', 'cpu', 'units') || 1)
gpus = server.dig('configuration', 'gpu', 'units') || 0
min_memory = server['configuration']['ram'].map do |el|
  el['units'].to_i * el['capacity'].to_i
end.reduce(:+)

PROVIDER_INSTANCES_DATA = File.join(File.dirname(__FILE__), "#{PROVIDER}_instances.json")

Instance = Struct.new(:name, :vcpu, :memory, :gpu, :carbon_cost)

instances = case File.file?(PROVIDER_INSTANCES_DATA)
                when true
                  instance_hash = JSON.load(File.read(PROVIDER_INSTANCES_DATA))
                  instance_hash.map do |i|
                    next unless i['carbon_cost']
                    Instance.new(
                      i['name'],
                      i['vcpu'],
                      i['memory'],
                      i['gpu'],
                      i['carbon_cost']
                    )
                  end.compact
                else
                  puts "Fetching instance types..."
                  instance_hash = list_instance_types(PROVIDER)

                  instances = instance_hash.map do |k,i|
                    cost = query_cloud_cost(k)
                    next unless cost
                    Instance.new(
                      k,
                      i['vcpu']['default'].to_i,
                      i['memory']['default'].to_i,
                      i['gpu_units']['default'].to_i,
                      cost
                    )
                  end.compact.tap do |is|
                    File.open(PROVIDER_INSTANCES_DATA, 'w') { |f| f.write(is.map(&:to_h).to_json)}
                  puts "Instance types cached at #{File.expand_path(PROVIDER_INSTANCES_DATA)}"
                  end
                end

filtered = instances.select do |p|
  p.vcpu >= vcpus &&
    p.memory >= min_memory &&
    p.gpu >= gpus
end

mins = filtered.min(5) do |a,b|
  a.carbon_cost <=> b.carbon_cost
end

puts "Best options on AWS:\n---"
mins.each do |instance|
  puts "#{instance.name}"
  puts "vCPUs: #{instance.vcpu}"
  puts "GPUs: #{instance.gpu}"
  puts "Memory: #{instance.memory}"
  puts "Yearly carbon cost for #{server_count} of them: #{instance.carbon_cost * server_count} kgCO2eq\n\n"
end
