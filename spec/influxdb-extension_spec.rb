require "sensu/extensions/influxdb"
require "sensu/logger"

describe "Sensu::Extension::InfluxDB" do

  before do
    @extension = Sensu::Extension::InfluxDB.new
    @extension.settings = Hash.new
    @extension.settings["influxdb-extension"] = {
        :database => "test",
        :hostname => "nonexistinghost",
        :additional_handlers => ["proxy"],
        :buffer_size => 5,
        :buffer_max_age => 1
    }
    @extension.settings["proxy"] = {
        :proxy_mode => true
    }
    
    @extension.instance_variable_set("@logger", Sensu::Logger.get(:log_level => :fatal))
    @extension.post_init
  end

  it "processes minimal event" do
    @extension.run(minimal_event.to_json) do 
      buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
      expect(buffer[0]).to eq("check_name rspec=69 1480697845")
    end
  end

  
  it "skips events with invalid timestamp" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "rspec 69 invalid"
      }
    }

    @extension.run(event.to_json) do 
      buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
      expect(buffer.size).to eq(0)
    end
  end

  
  it "flushes buffer when full" do
    5.times {
      @extension.run(minimal_event.to_json) do |output,status|
        expect(output).to eq("ok")
        expect(status).to eq(0)
      end
    }
    # flush buffer will fail writing to bogus influxdb
    2.times {
      @extension.run(minimal_event.to_json) do |output,status|
        expect(output).to eq("error")
        expect(status).to eq(2)
      end
    }
  end

  it "flushes buffer when timed out" do
    @extension.run(minimal_event.to_json) do end
    sleep(1)
    @extension.run(minimal_event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer.size).to eq(1)
  end

  it "sorts event tags alphabetically" do
    event = {
      "client" => {
        "name" => "rspec",
        "tags" => {
          "x" => "1",
          "z" => "1",
          "a" => "1"
        }
      },
      "check" => {
        "name" => "check_name",
        "output" => "rspec 69 1480697845",
        "tags" => {
          "b" => "1",
          "c" => "1",
          "y" => "1"
        }
      }
    }
    
    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,a=1,b=1,c=1,x=1,y=1,z=1 rspec=69 1480697845")
  end

  it "Accepting output formats" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.apache.request 69 1480697845",
        "influxdb" => {"output_formats" => ['host.type.metric']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name,type=apache request=69 1480697845")
  end

  it "Accepting underscore in formats" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.apache.unwanted.request 69 1480697845",
        "influxdb" => {"output_formats" => ['host.type._.metric']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name,type=apache request=69 1480697845")
  end

  it "Accepting fieldset with same tagset" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.apache.unwanted.request 69 1480697845\nhost_name.apache.unwanted.errors 1 1480697845",
        "influxdb" => {"output_formats" => ['host.type._.metric']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name,type=apache request=69,errors=1 1480697845")
  end

  it "Accepting fieldset with different tagset" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.server1.unwanted.request 69 1480697845\nhost_name.server2.unwanted.errors 1 1480697845",
        "influxdb" => {"output_formats" => ['host.type._.metric']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name,type=server1 request=69 1480697845")
    expect(buffer[1]).to eq("check_name,host=host_name,type=server2 errors=1 1480697845")
  end

  it "ignoring fields different tags" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.server1.unwanted.request 69 1480697845\nhost_name.server1.unwanted.timeout 0 1480697845\nhost_name.server1.unwanted.request1 69 1480697845\nhost_name.server2.unwanted.errors 1 1480697845",
        "influxdb" => {"output_formats" => ['host.type._.metric'], "ignore_fields" => ['request', 'request1']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name,type=server1 timeout=0 1480697845")
    expect(buffer[1]).to eq("check_name,host=host_name,type=server2 errors=1 1480697845")
  end

  it "ignoring fields with same tags" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.server1.unwanted.request 69 1480697845\nhost_name.server1.unwanted.timeout 0 1480697845\nhost_name.server1.unwanted.request1 69 1480697845\nhost_name.server1.unwanted.errors 1 1480697845",
        "influxdb" => {"output_formats" => ['host.type._.metric'], "ignore_fields" => ['request', 'request1']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name,type=server1 timeout=0,errors=1 1480697845")
    expect(buffer[1]).to eq(nil)
  end

  it "Accepting metric*" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.server1.unwanted.request 69 1480697845",
        "influxdb" => {"output_formats" => ['host.metric*']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name server1.unwanted.request=69 1480697845")
    expect(buffer[1]).to eq(nil)
  end

  it "Accepting metric* with underscore _" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.server1.unwanted.request 69 1480697845",
        "influxdb" => {"output_formats" => ['_.metric*']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name server1.unwanted.request=69 1480697845")
    expect(buffer[1]).to eq(nil)
  end

  it "Accepting metric* with same tagset" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.apache.unwanted.request 69 1480697845\nhost_name.apache.unwanted.errors 1 1480697845",
        "influxdb" => {"output_formats" => ['host.type.metric*']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name,type=apache unwanted.request=69,unwanted.errors=1 1480697845")
    expect(buffer[1]).to eq(nil)
  end

  it "Accepting metric* with different tagset" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.server1.unwanted.request 69 1480697845\nhost_name.server1.unwanted.timeout 0 1480697845\nhost_name.server1.unwanted.request1 69 1480697845\nhost_name.server2.unwanted.errors 1 1480697845",
        "influxdb" => {"output_formats" => ['host.type.metric*']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name,type=server1 unwanted.request=69,unwanted.timeout=0,unwanted.request1=69 1480697845")
    expect(buffer[1]).to eq("check_name,host=host_name,type=server2 unwanted.errors=1 1480697845")
    expect(buffer[2]).to eq(nil)
  end

  it "Accepting metgric*, ignoring fields different tags" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.server1.unwanted.request 69 1480697845\nhost_name.server1.unwanted.timeout 0 1480697845\nhost_name.server1.unwanted.request1 69 1480697845\nhost_name.server2.unwanted.errors 1 1480697845",
        "influxdb" => {"output_formats" => ['host.type.metric*'], "ignore_fields" => ['unwanted.request', 'unwanted.request1']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name,type=server1 unwanted.timeout=0 1480697845")
    expect(buffer[1]).to eq("check_name,host=host_name,type=server2 unwanted.errors=1 1480697845")
  end

  it "Accepting metric*, ignoring fields with same tags" do
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "host_name.server1.unwanted.request 69 1480697845\nhost_name.server1.unwanted.timeout 0 1480697845\nhost_name.server1.unwanted.request1 69 1480697845\nhost_name.server1.unwanted.errors 1 1480697845",
        "influxdb" => {"output_formats" => ['host.type.metric*'], "ignore_fields" => ['unwanted.request', 'unwanted.request1']}
      }
    }

    @extension.run(event.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["influxdb-extension"]["buffer"]
    expect(buffer[0]).to eq("check_name,host=host_name,type=server1 unwanted.timeout=0,unwanted.errors=1 1480697845")
    expect(buffer[1]).to eq(nil)
  end

  it "does not modify input in proxy mode" do
    @extension.run(minimal_event_proxy.to_json) do end

    buffer = @extension.instance_variable_get("@handlers")["proxy"]["buffer"]
    expect(buffer[0]).to eq("rspec 69 1480697845")
  end

end

def minimal_event
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "name" => "check_name",
        "output" => "rspec 69 1480697845"
      }
    }
end

def minimal_event_proxy
    event = {
      "client" => {
        "name" => "rspec"
      },
      "check" => {
        "check_name" => "check_name",
        "handlers" => ["proxy"],
        "output" => "rspec 69 1480697845"
      }
    }
end
