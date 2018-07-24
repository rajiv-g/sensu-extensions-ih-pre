#!/usr/bin/env ruby
# coding: utf-8

require "sensu/extension"
require "net/http"
require "json"

module Sensu::Extension
  class InfluxDB < Handler

    @@extension_name = "influxdb-extension"

    def name
      @@extension_name
    end

    def description
      "Transforms and sends metrics to InfluxDB"
    end

    @@default_config = {
      :hostname       => "127.0.0.1",
      :port           => "8086",
      :ssl            => false,
      :precision      => "s",
      :protocol       => "http",
      :buffer_size    => 100,
      :buffer_max_age => 10,
      :proxy_mode     => false
    }

    def create_config(name, defaults)
      if settings[name].nil?
        Raise ArgumentError "no configuration for #{name} provided. exiting..."
      end
      config = defaults.merge(settings[name])
      @logger.debug("Config for #{name} created: #{config}")
      validate_config(name, config)

      hostname         = config[:hostname]
      port             = config[:port]
      database         = config[:database]
      ssl              = config[:ssl]
      ssl_ca_file      = config[:ssl_ca_file]
      ssl_verify       = if config.key?(:ssl_verify) then config[:ssl_verify] else true end
      precision        = config[:precision]
      retention_policy = config[:retention_policy]
      rp_queryparam    = if retention_policy.nil? then "" else "&rp=#{retention_policy}" end
      protocol         = if ssl then "https" else "http" end
      username         = config[:username]
      password         = config[:password]
      auth_queryparam  = if username.nil? or password.nil? then "" else "&u=#{username}&p=#{password}" end
      buffer_size      = config[:buffer_size]
      buffer_max_age   = config[:buffer_max_age]
      proxy_mode       = config[:proxy_mode]
      custom_measurements   = if config.key?(:custom_measurements) then config[:custom_measurements] else [] end
      string = "#{protocol}://#{hostname}:#{port}/write?db=#{database}&precision=#{precision}#{rp_queryparam}#{auth_queryparam}"
      uri = URI(string)
      http = Net::HTTP::new(uri.host, uri.port)
      if ssl
        http.ssl_version = :TLSv1
        http.use_ssl = true
        http.verify_mode = if ssl_verify then OpenSSL::SSL::VERIFY_PEER else OpenSSL::SSL::VERIFY_NONE end
        http.ca_file = ssl_ca_file
      end

      @handlers ||= Hash.new
      @handlers[name] = {
        "http" => http,
        "uri" => uri,
        "buffer" => [],
        "buffer_flushed" => Time.now.to_i,
        "buffer_size" => buffer_size,
        "buffer_max_age" => buffer_max_age,
        "proxy_mode" => proxy_mode,
        "custom_measurements" => custom_measurements
      }

      @logger.info("#{name}: successfully initialized handler: hostname: #{hostname}, port: #{port}, database: #{database}, uri: #{uri.to_s}, username: #{username}, buffer_size: #{buffer_size}, buffer_max_age: #{buffer_max_age}")
      return config
    end

    def post_init
      main_config = create_config(@@extension_name, @@default_config)
      if settings[name].key?(:additional_handlers)
        settings[name][:additional_handlers].each {|h| create_config(h, main_config)}
      end
    end

    def run(event)
      begin
        @logger.debug("event: #{event}")
        event = JSON.parse(event)

        handler = @handlers[@@extension_name]
        unless event["check"]["handlers"].nil?
          event["check"]["handlers"].each {|x|
            if @handlers.has_key?(x)
              @logger.debug("found additional handler: #{x}")
              handler = @handlers[x]
              break
            end
          }
        end

        if buffer_too_old?(handler) or buffer_too_big?(handler)
          flush_buffer(handler)
        end

        output = event["check"]["output"]

        if not handler["proxy_mode"]
          client_tags = event["client"]["tags"] || Hash.new
          check_tags = event["check"]["tags"] || Hash.new
          tags = create_tags(client_tags.merge(check_tags))
        end

        point_set = [] # Used to store the tags & field set in the format point_set = [ {measurement: <measurement_name>, tags: {}, fields: {}, timestamp:<timestamp>}, {tags: {}, fields: {}, timestamp: <timestamp>}, ... ]
        key_array = [] # Used to store metric parts thereby access prefix
        output_formats = []
        measurement = event['check']['name'] if event['check']['name']
        output.split(/\r\n|\n/).each do |point|
          if not handler["proxy_mode"]
            buckets, field_value, timestamp = point.scan(/'([^']+)'|"([^"]+)"|(\S+)/).flatten.compact

            # Accept string fields
            string_fields = []
            string_fields = event['check']['influxdb']['string_fields'] if event['check']['influxdb'] && event['check']['influxdb']['string_fields']
            field_value = (!is_number?(field_value) || string_fields.any? { |f| buckets.include? f }) ? "\"#{field_value}\"" : field_value
            measurement = event['check']['name']
            key_array = buckets.split('.')
            next if event['check']['influxdb']['ignore_fields'].any? { |f| buckets[f] } if event['check']['influxdb'] && event['check']['influxdb']['ignore_fields']

            if not is_number?(timestamp)
              @logger.debug("invalid timestamp, skipping line in event #{event}")
              next
            end

            # Get event output tags
            if buckets.include?('eventtags')
              only_measurement, tagstub = buckets.split('.eventtags.',2)
              event_tags = Hash.new()
              tagstub.split('.').each_slice(2) do |key, value|
                event_tags[key] = value
              end
              measurement = only_measurement
              tags = create_tags(client_tags.merge(check_tags).merge(event_tags))
            end

            # List output formats by measurements
            custom_formats = []
            handler['custom_measurements'].each do |sfs|
              if sfs[:apply_only_for_checks]
                next unless sfs[:apply_only_for_checks].include? event['check']['name'] # Match wih checks
              end
              sfs[:measurement_formats].each do |f|
                custom_formats << {sfs[:measurement_name] => f}
              end
            end

            # Allow Output formats, with custom_format has priority
            output_formats = event['check']['influxdb']['output_formats'] if event['check']['influxdb'] && event['check']['influxdb']['output_formats']
            
            output_formats = custom_formats + output_formats
            p output_formats if event['check']['name'] == 'random1'
            custom_tags = {}
            metric = buckets

            if output_formats
              output_formats_matched = false
              output_formats.each_with_index do |format_object|
                break if output_formats_matched

                format = format_object # No change when it is string
                custom_measurement_name = nil
                if format_object.is_a?(Hash)
                  custom_measurement_name = format_object.keys[0]
                  format = format_object[format_object.keys[0]]
                end
                format_array = format.split('.')

                # Check matching format
                next unless match_formats?(format_array, key_array, {custom_measurement_name: custom_measurement_name})
                output_formats_matched = true
                format_array.zip(key_array).each do |k, v|
                  next if k == '_' # Ignore tagging when using _ placeholder.
                  if k == 'metric'
                    metric = v
                    next
                  end
                  if k == 'metric*'
                    metric = buckets[/(#{v}\..*|#{v}$)/] # Extract all metric* part & avoid greedy
                    break
                  end

                  if k == 'measurement'
                    measurement = v
                    next
                  end

                  custom_tags[k] = v
                end
              end
            else
              custom_tags['metric'] = measurement
            end

            # Check already tags present in point set.
            tags_timestamp_match = false
            point_set.each do |point|
              if point['tags'] == custom_tags && point['timestamp'] == timestamp && point['measurement'] == measurement
                point['fields'][metric] = field_value
                tags_timestamp_match = true
                break
              end
            end

            # Create the new tag set if point_set tags not match
            unless tags_timestamp_match
              point_set << {'measurement' => measurement, 'tags' => custom_tags, 'fields' => {metric => field_value}, 'timestamp' => timestamp }
            end
          else
            handler["buffer"].push(point)
          end
        end
        point_set.each do |point|
          tags = create_tags(client_tags.merge(check_tags).merge(point['tags'])) # metric tags are ignored and moved to field
          fields = point['fields'].map{|k,v| "#{k}=#{v}"}.join(',')
          timestamp = point['timestamp']
          point = "#{point['measurement']}#{tags} #{fields} #{timestamp}"
          handler["buffer"].push(point)
          @logger.debug("#{@@extension_name}: stored point in buffer (#{handler['buffer'].length}/#{handler['buffer_size']})")
        end
        # End of Output formats
        yield 'ok', 0
      rescue => e
        @logger.error("#{@@extension_name}: unable to handle event #{event} - #{e}")
        yield 'error', 2
      end
    end

    def create_tags(tags)
        begin
            # sorting tags alphabetically in order to increase influxdb performance
            sorted_tags = Hash[tags.sort]

            tag_string = ""

            sorted_tags.each do |tag, value|
                next if value.to_s.empty? or tag == 'metric' # skips tags without values & metric
                tag_string += ",#{tag}=#{value}"
            end

            @logger.debug("#{@@extension_name}: created tags: #{tag_string}")
            tag_string
        rescue => e
            @logger.debug("#{@@extension_name}: unable to create tag string from #{tags} - #{e.backtrace.to_s}")
            ""
        end
    end

    def send_to_influxdb(handler)
      payload = handler["buffer"].join("\n")
      request = Net::HTTP::Post.new(handler['uri'].request_uri)
      request.body = payload

      @logger.debug("#{@@extension_name}: writing payload #{payload} to endpoint #{handler['uri'].to_s}")
      response = handler["http"].request(request)
      @logger.debug("#{@@extension_name}: influxdb http response code = #{response.code}, body = #{response.body}")
    end

    def flush_buffer(handler)
      send_to_influxdb(handler)
      handler["buffer"] = []
      handler["buffer_flushed"] = Time.now.to_i
    end

    def buffer_too_old?(handler)
      buffer_age = Time.now.to_i - handler["buffer_flushed"]
      buffer_age >= handler["buffer_max_age"]
    end

    def buffer_too_big?(handler)
      handler["buffer"].length >= handler["buffer_size"]
    end

    def validate_config(name, config)
      if config.nil?
        raise ArgumentError, "no configuration for #{name} provided. exiting..."
      end

      ["hostname", "database"].each do |required_setting|
        if config.has_key?(required_setting)
          raise ArgumentError, "required setting #{required_setting} not provided to extension. this should be provided as json element with key #{name}. exiting..."
        end
      end
    end

    def is_number?(input)
      true if Float(input) rescue false
    end
    
    def match_formats?(format_array, key_array, criteria)
      return (format_array.length == key_array.length or format_array.include? 'metric*') unless format_array.include? 'measurement'

      # For measurement criteria
      matched = false
      format_array.zip(key_array).each do |k,v|
        return false if (k == nil or v == nil) # Anyone becomes nill
        matched = (k == 'measurement') ? v == criteria[:custom_measurement_name] : matched
      end
      return matched
    end
  end
end
