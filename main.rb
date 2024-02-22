# frozen_string_literal: true

require 'yaml'
require 'faraday'
require 'json'
require 'fileutils'

def boavizta
  @boavizta ||= Faraday.new(BOAVIZTA_URL)
end

def read_yaml(path)
  YAML.load_file(path)
rescue Errno::ENOENT
  raise "File doesn't exist"
end

def generate_server(server)
  return server if !server['name']
  response = boavizta.get('/v1/server/archetype_config') do |req|
    req.headers[:content_type] = 'application/json'
    req.params[:verbose] = false
    req.params[:archetype] = server['name']
  end
  data = JSON.parse(response.body)

  cpu_name = server.dig('cpu', 'name') || data.dig('CPU', 'name', 'default')
  if cpu_name
    response = boavizta.get('/v1/utils/name_to_cpu') do |req|
      req.headers[:content_type] = 'application/json'
      req.params[:verbose] = false
      req.params[:cpu_name] = cpu_name
    end
    cpu_data = JSON.parse(response.body)
  end

  {
    'cpu' => {
      'units' => server.dig('cpu', 'units') || data.dig('CPU', 'units', 'default'),
      'core_units' => server.dig('cpu', 'core_units') ||
                      data.dig('CPU', 'core_units', 'default') ||
                      cpu_data.dig('core_units'),
      'tdp' => server.dig('cpu', 'tdp') || cpu_data.dig('tdp'),
      'name' => cpu_name,
      'family' => server.dig('cpu', 'family') || cpu_data.dig('family')
      },
    'gpu' => {
      'units' => server.dig('gpu', 'units') || data.dig('GPU', 'units', 'default')
      },
    'ram' => {
      'units' => server.dig('ram', 'units') || data.dig('RAM', 'units', 'default'),
      'capacity' => server.dig('ram', 'capacity') || data.dig('RAM', 'capacity', 'default')
      },
    'count' => server['count'] || 1
  }
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
  puts "Cluster manufacture cost: #{manufacture} kgCO2eq"
  puts "Cluster usage cost: #{usage} kgCO2eq"

  total = manufacture + usage
  lifetime = (cluster['usage']['hours_life_time'] / 24.0 / 365).ceil
  per_year = total / lifetime

  puts "\nTotal cost: #{total} kgCO2eq"
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

  {
    manufacture: gwp['embedded']['value'],
    use: gwp['use']['value']
  }
rescue JSON::ParserError
  puts "failed to grab carbon cost for '#{instance_type}'"
  nil
end

args = Hash[ARGV.join(' ').scan(/--?([^=\s]+)(?:=(\S+))?/)]

Instance = Struct.new(:name, :vcpu, :memory, :gpu, :manu_cost, :usage_cost)

BOAVIZTA_URL = ENV['BOAVIZTA_ENDPOINT_URL']
PROVIDER_MAPPER = { aws: 'AWS', alces: 'Alces Cloud' }.freeze
PROVIDER = args['provider']
PROVIDER_NAME = PROVIDER_MAPPER[PROVIDER.to_s.downcase.to_sym]
CLUSTER = args['cluster']

raise "Provider '#{args['provider']}' doesn't exist" unless PROVIDER_NAME
raise 'No cluster given' unless args['cluster']

cluster = read_yaml(CLUSTER)

cluster['configuration'].map!{ |server| generate_server(server) }

puts "On prem usage:\n"
print_usage!(cluster)
puts '---'

alces_cluster = cluster.dup
alces_cluster['usage']['usage_location'] = 'SWE'
alces_cluster['usage']['hours_life_time'] = 70_080
puts "\nThe same system, but in Sweden over 8 years:\n"
print_usage!(alces_cluster)
puts

servers = cluster['configuration']
PROVIDER_INSTANCES_DATA = File.join(File.dirname(__FILE__), "#{PROVIDER}_instances.json")
available_instances =
  case File.file?(PROVIDER_INSTANCES_DATA)
  when true
    instance_hash = JSON.parse(File.read(PROVIDER_INSTANCES_DATA))
    instance_hash.map do |i|
      next unless i['manu_cost'] # Row is useless unless it has cost data

      Instance.new(
        i['name'],
        i['vcpu'],
        i['memory'],
        i['gpu'],
        i['manu_cost'],
        i['usage_cost']
      )
    end.compact
  else
    puts 'Fetching instance types...'
    instance_hash = list_instance_types(PROVIDER)

    instances = instance_hash.map do |k, i|
      costs = query_cloud_cost(k)
      next unless costs

      Instance.new(
        k,
        i['vcpu']['default'].to_i,
        i['memory']['default'].to_i,
        i['gpu_units']['default'].to_i,
        costs[:manufacture],
        costs[:use]
      )
    end
    instances.compact.tap do |is|
      File.open(PROVIDER_INSTANCES_DATA, 'w') { |f| f.write(is.map(&:to_h).to_json) }
      puts "Instance types cached at #{File.expand_path(PROVIDER_INSTANCES_DATA)}"
    end
  end

puts "Best options on #{PROVIDER_NAME}:\n---"
servers.each do |server|
  vcpus =
    (server.dig('cpu', 'core_units') || 1) *
    (server.dig('cpu', 'units') || 1)
  gpus = server.dig('gpu', 'units') || 0
  min_memory = server.dig('ram', 'units') * server.dig('ram', 'capacity')

  filtered = available_instances.select do |p|
    p.vcpu >= vcpus &&
      p.memory >= min_memory &&
      p.gpu >= gpus
  end

  mins = filtered.min(1) do |a, b|
    (a.manu_cost + a.usage_cost) <=> (b.manu_cost + b.usage_cost)
  end

  mins.each do |instance|
    manufacture = instance.manu_cost
    usage = instance.usage_cost

    total = manufacture + usage

    puts instance.name
    puts "vCPUs: #{instance.vcpu}"
    puts "GPUs: #{instance.gpu}"
    puts "Memory: #{instance.memory}"
    puts "Manufacture cost: #{manufacture} kgCO2eq"
    puts "Usage cost: #{usage} kgCO2eq"
    puts "Yearly carbon cost for #{server['count']} of them: #{total * server['count']} kgCO2eq\n\n"
  end
end
