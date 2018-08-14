require 'rspec-benchmark'

RSpec.configure do |config|
  config.include RSpec::Benchmark::Matchers
end

describe "Sensu::Extension::InfluxDB" do

  before do
    @extension = Sensu::Extension::InfluxDB.new
    @extension.settings = Hash.new
    @extension.settings["influxdb-extension"] = {
        :database => "test",
        :hostname => "nonexistinghost",
        :additional_handlers => ["proxy"],
        :buffer_size => 5,
        :buffer_max_age => 1,
        :custom_measurements => [
          {:measurement_name => 'measurement1', :measurement_formats => ['_._.measurement.htype.metric*', '_.measurement.metric*'], :apply_only_for_checks => ['statsd']},
          {:measurement_name => 'measurement2', :measurement_formats => ['_._.measurement.htype.metric*','_.measurement.htype.metric*']},
          {:measurement_name => 'measurement3', :measurement_formats => ['_._.measurement.metric'], :apply_only_for_checks => ['other']},
          {:measurement_name => 'measurement_all', :measurement_formats => ['_._.measurement.metric']},
          {:measurement_name => 'measurement_tag', :measurement_formats => ['_._.measurement.metric']},
        ]
    }
    @extension.settings["proxy"] = {
        :proxy_mode => true
    }
    
    @extension.instance_variable_set("@logger", Sensu::Logger.get(:log_level => :fatal))
    @extension.post_init
  end

  # Check performance for 200 server * [(20 sensu measurements)*(10 metrics each) + 50 statsd metrics)] per 60 second
  # Approximatly 200*(200 + 50) = 50000 metric / per minute => ~800 metrics / per second
  it "Check performance for 200 server * [(20 sensu metrics)*(10 metrics each) + 50 statsd metrics)] per 60 second" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "random1",
        "output" => "statsd.timers.embedded.metric1 1.0 1480697845\nstatsd.timers.tag.metric1 1.0 1480697845",
        "influxdb" => {"output_formats" => [{measurement_name: 'embedded', measurement_formats: ['_._.measurement.metric']}, '_._.type.metric']}
      }
    }

    @extension.run(event.to_json) do end

    expect { @extension.run(event.to_json) do end }.to perform_under(5).ms.and_sample(100)
    #expect { @extension.run(event.to_json) do end }.to perform_at_least(1000).ips
  end

end
