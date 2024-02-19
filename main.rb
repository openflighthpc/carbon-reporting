# frozen_string_literal: true

require 'yaml'
require 'faraday'
require 'json'
require 'fileutils'

ARGS = Hash[ARGV.join(' ').scan(/--?([^=\s]+)(?:=(\S+))?/)]

def boavizta
  @boavizta ||= Faraday.new(BOAVIZTA_URL)
end

def read_yaml(path)
  YAML.load_file(path)
rescue Errno::ENOENT
  raise "File doesn't exist"
end

def carbon_costs_per_year(server, use_ratio: 1, location: 'WOR')
  # Boavizta expects the RAM entry to be an array, for some (no?) reason
  server = server.dup.tap { |s| s['ram'] = [s['ram']] }

  response = boavizta.post('/v1/server/') do |req|
    req.headers[:content_type] = 'application/json'
    req.params[:verbose] = false
    req.body = JSON.generate(
      {
        'configuration' => server,
        'usage' => {
          'use_time_ratio' => use_ratio,
          'hours_life_time' => 8760,
          'usage_location' => location
        }
      }
    )
  end

  data = JSON.parse(response.body)

  {
    manufacture: data.dig(*%w[impacts gwp embedded value]),
    usage: data.dig(*%w[impacts gwp use value])
  }
end

def print_usage!(cluster)
  manufacture = 0
  usage = 0
  servers = cluster['configuration']

  servers.each do |server|
    costs = carbon_costs_per_year(
      server,
      use_ratio: cluster.dig('usage', 'use_time_ratio'),
      location: cluster.dig('usage', 'usage_location')
    )
    manufacture += costs[:manufacture] * server['count']
    usage += costs[:usage] * server['count']
  end

  total = manufacture + usage
  lifetime = (cluster['usage']['hours_life_time'] / 24.0 / 365).ceil
  per_year = total / lifetime

  puts "Amortized carbon equivalent: #{per_year} kgCO2eq per year"
end

def list_instance_types(provider)
  response = boavizta.get('/v1/cloud/instance/all_instance_data') do |req|
    req.params[:provider] = provider
  end

  JSON.parse(response.body)['data']
end

def query_cloud_cost(instance_type, provider)
  response = boavizta.get('/v1/cloud/instance') do |req|
    req.params[:provider] = provider
    req.params[:instance_type] = instance_type.to_s
    req.params[:verbose] = false
    req.params[:criteria] = 'gwp'
    req.params[:duration] = 8760
  end

  gwp = JSON.parse(response.body)['impacts']['gwp']

  { manufacture: gwp['embedded']['value'], use: gwp['use']['value'] }
rescue JSON::ParserError
  puts "failed to grab carbon emission value for '#{instance_type}'" if ARGS['verbose']
  nil
end

def instance_list_filename(provider)
  File.join(File.dirname(__FILE__), "#{provider}_instances.json")
end

def cache_instance_list(provider)
  puts "Fetching instance types for '#{provider}'..."
  filename = instance_list_filename(provider)

  instances = list_instance_types(provider).map do |k, i|
    costs = query_cloud_cost(k, provider)
    next unless costs

    Instance.new(
      k, i['vcpu']['default'].to_i, i['memory']['default'].to_i,
      i['gpu_units']['default'].to_i, costs[:manufacture], costs[:use]
    )
  end

  instances.compact.tap do |is|
    File.open(filename, 'w') { |f| f.write(is.map(&:to_h).to_json) }
  end

  puts "Instance types for '#{provider}' cached at #{File.expand_path(filename)}"
end

def fetch_instance_list(provider)
  filename = instance_list_filename(provider)
  cache_instance_list(provider) unless File.file?(filename)

  instance_hash = JSON.parse(File.read(filename))

  # Row is useless unless it has cost data
  instance_hash.select! { |i| i['manu_cost'] }

  instance_hash.map do |i|
    Instance.new(i['name'], i['vcpu'], i['memory'], i['gpu'], i['manu_cost'],
                 i['usage_cost'])
  end
end

def bold(str)
  "\e[1m#{str}\e[22m"
end

Instance = Struct.new(:name, :vcpu, :memory, :gpu, :manu_cost, :usage_cost)

BOAVIZTA_URL = ENV['BOAVIZTA_ENDPOINT_URL']
PROVIDERS = [
  {
    id: :aws,
    name: 'AWS'
  },
  {
    id: :alces,
    name: 'Alces Cloud'
  }
].freeze
CLUSTER_FILE = ARGS['cluster']

raise 'No cluster given' unless ARGS['cluster']

cluster = read_yaml(CLUSTER_FILE)

puts bold("On prem usage:\n---")
print_usage!(cluster)

# Deep copy so we can change new cluster without updating main one
alces_cluster = Marshal.load(Marshal.dump(cluster))
alces_cluster['usage']['usage_location'] = 'SWE'
alces_cluster['usage']['hours_life_time'] = 70_080
puts bold("\nThe same system, but in Sweden over 8 years:\n---")
print_usage!(alces_cluster)
puts

servers = cluster['configuration']

PROVIDERS.each do |provider|
  available_instances = fetch_instance_list(provider[:id])
  total = 0
  types_used = []

  servers.each do |server|
    vcpus = (server.dig('cpu', 'core_units') || 1) * (server.dig('cpu', 'units') || 1)
    gpus = server.dig('gpu', 'units') || 0
    min_memory = server.dig('ram', 'units') * server.dig('ram', 'capacity')

    filtered = available_instances.select do |p|
      p.vcpu >= vcpus && p.memory >= min_memory && p.gpu >= gpus
    end

    min = filtered.min do |a, b|
      (a.manu_cost + a.usage_cost) <=> (b.manu_cost + b.usage_cost)
    end

    next unless min

    types_used << { name: min.name, count: server['count'] }
    manufacture = min.manu_cost
    usage = min.usage_cost
    total += (manufacture + usage) * server['count']
  end

  lifetime = (cluster['usage']['hours_life_time'] / 24.0 / 365).ceil
  amortized = total / lifetime
  puts bold("Best options on #{provider[:name]}\n---")
  instances = types_used.map { |t| "#{t[:count]}x #{t[:name]}" }
  puts "Instances used: #{instances.join(', ')}"
  puts "Amortized carbon equivalent: #{amortized} kgCO2eq per year\n\n"
end



