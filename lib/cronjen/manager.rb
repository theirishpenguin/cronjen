require 'jenkins_api_client'

module Cronjen

  class UsageError < StandardError ; end
  class CronSyntaxError < StandardError ; end
  class CronPlusSyntaxError < StandardError ; end
  class ConfigError < StandardError ; end

  class Manager

    def initialize(command, inventory_key)
      @command = command
      @inventory_key = inventory_key

      return if @command.to_s == 'init'

      fail_if_bad_configuration_or_usage
      initialize_client
      initialize_logger
    end

    def execute_command
      __send__(@command)
    end

    private

    def init
      if File.exist?(private_config_filepath)
        puts "\nWarning: A private config file already exists at '#{private_config_filepath}'. You can edit this manually (or delete it and rerun './cronjen init'). Skipping private config questions.\n\n"
      else
        puts "\nFirstly, some questions about your configuration...\n"
        initialize_private_config_file
      end

      if File.exist?(project_config_filepath)
        puts "\nNow, some questions about your project's configuration...\n"
        puts "\nWarning: A project config file already exists at '#{project_config_filepath}'. You can edit this manually (or delete it and rerun 'cronjen init'). Skipping project config questions.\n\n"
      else
        initialize_project_config_file
      end
    end

    def list
      crontab_defn = []

      # List existing scheduled jobs for that server
      @client.job.list("^#{job_prefix}").each do |full_job_name|
        # Easier to get the command from the standard ruby jenkins api
        job_details = @client.job.list_details(full_job_name)
        job_params = job_details["property"].find{ |prop| prop.has_key?("parameterDefinitions") }["parameterDefinitions"]
        login_user_text = job_params.find{|param| param['defaultParameterValue']["name"] == "loginuser"}['defaultParameterValue']['value']

        # If available take the cronjen plus syntax, otherwise we fall back to the remote command to run
        cronjen_plus_params = job_params.find{|param| param['defaultParameterValue']["name"] == "cronjen_plus_command"}

        if cronjen_plus_params.nil? or cronjen_plus_params.empty? or cronjen_plus_params['defaultParameterValue']['value'].empty?
          command_text = job_params.find{|param| param['defaultParameterValue']["name"] == "command"}['defaultParameterValue']['value']
        else
          command_text = cronjen_plus_params['defaultParameterValue']['value']
        end

        # However we need to get back the job config as xml to get the schedule (including the timezone)
        xml = @client.job.get_config(full_job_name)
        n_xml = Nokogiri::XML(xml)
        tz_and_schedule = n_xml.xpath("//triggers/hudson.triggers.TimerTrigger/spec").first.content.split("\n")
        tz = tz_and_schedule[0].gsub('TZ=', '')
        schedule_text = tz_and_schedule[1]
        unique_name = full_job_name.gsub("#{job_prefix} - ", '')
        cron_line = "#{schedule_text} | #{tz} | #{login_user_text} | #{unique_name} | #{command_text}"
        crontab_defn << cron_line
      end
      puts "The jenkins cron on the server now looks like:"
      puts ""
      puts "# Schedule | Timezone | Running User | Unique Name | Command"
      puts crontab_defn
    end

    def clear
      silent_clear
      list
    end

    # Delete existing scheduled jobs for that server
    def silent_clear
      @client.job.list("^#{job_prefix}").each do |full_job_name|
        @client.job.delete(full_job_name)
      end
    end

    # Create new scheduled jobs for that server
    def install
      silent_clear
      raise_error_if_repeating_cronjob_names

      job_defn_list.each do |job_defn|
        create_job_in_jenkins(job_defn)
      end

      list
    end

    def create_job_in_jenkins(job_defn)

      jenkins_command, remote_command, cronjen_plus_command = extract_commands(job_defn)

      # Build basic job definition and substitute fields
      initial_job_config_xml = template_content('job.xml')
        .gsub('__HOST_VALUE__', inventory_item['target_host_url'].encode(:xml => :text))
        .gsub('__SCHEDULE_VALUE__', job_defn[:schedule].encode(:xml => :text))
        .gsub('__TZ_VALUE__', job_defn[:tz].encode(:xml => :text))
        .gsub('__RUNNING_USER__', job_defn[:running_user].to_s.encode(:xml => :text))
        .gsub('__REMOTE_COMMAND_VALUE__', remote_command.encode(:xml => :text))
        .gsub('__CRONJEN_PLUS_COMMAND_VALUE__', cronjen_plus_command.encode(:xml => :text))
        .gsub('__JENKINS_COMMAND_VALUE__', jenkins_command.encode(:xml => :text))
        .gsub('__EMAIL_RECIPIENTS_VALUE__', project_config['email_recipients'].to_s.encode(:xml => :text))
        .gsub('__LOG_NUM_TO_KEEP_VALUE__', project_config['log_num_to_keep'].to_s.encode(:xml => :text))

      # Configure the job definition with any supported plugins
      #
      # Notes
      # * BuildDiscarderProperty managed by project config's "log_num_to_keep"
      # * Not doing anything with project/concurrentBuild at the moment

      doc = Nokogiri::XML(initial_job_config_xml)

      configure_support_for_plugin('throttle-concurrents',
        'project/properties/hudson.plugins.throttleconcurrents.ThrottleJobProperty', doc)

      if !project_config['email_recipients'].to_s.empty? and !installed_plugins.has_key? 'mailer'
        raise ConfigError, bad_email_configuration_message
      end

      configure_support_for_plugin('mailer',
        'project/publishers/hudson.tasks.Mailer', doc)

      configure_support_for_plugin('timestamper',
        'project/buildWrappers/hudson.plugins.timestamper.TimestamperBuildWrapper', doc)

      job_config_xml = doc.to_xml
      full_job_name = "#{job_prefix} - #{job_defn[:unique_name]}"

      if @client.job.create(full_job_name, job_config_xml)
        puts "Created #{full_job_name}"
      end
    end

    def extract_commands(job_defn)
      if job_defn[:command].strip.upcase.start_with? ('CRONJEN_PLUS')
        # We are dealing with a special command and must parse/handle accordingly
        jenkins_command, remote_command = extract_cronjen_plus_command(job_defn[:command])
        cronjen_plus_command = job_defn[:command]
      else # Regular cronjen command
        jenkins_command = project_config['ssh_command']
        remote_command = job_defn[:command]
        cronjen_plus_command = ''
      end

      [jenkins_command, remote_command, cronjen_plus_command]
    end

    def extract_cronjen_plus_command(job_defn_command)
      command_json = /\s*CRONJEN_PLUS\s*:\s*(.*)/.match(job_defn_command)[1]
      cmd_defn = JSON.parse(command_json)
      remote_command = ''
      jenkins_command = ''
      if cmd_defn['type'] == 'aws_instance_starter'
        jenkins_command = template_content('aws_instance_starter.sh')
          .gsub('__AWS_REGION_VALUE__', cmd_defn['region'])
        remote_command = ''
      elsif cmd_defn['type'] == 'aws_fire_and_forget'
        jenkins_command = template_content('aws_fire_and_forget.sh')
          .gsub('__AWS_REGION_VALUE__', cmd_defn['region'])
          .gsub('__SSH_COMMAND_VALUE__', project_config['ssh_command'])
        remote_command = cmd_defn['cmd']
      else
        raise CronPlusSyntaxError, "No such CRONJEN_PLUS command '#{cmd_defn['type']}'. The full command in the cron is:\n\n#{job_defn_command}"
      end

      [jenkins_command, remote_command]
    end

    def template_content(template_name)
      File.read(template_dirpath(template_name))
    end

    def job_defn_list
      return @job_defn_list if @job_defn_list

      raise ConfigError, "Bad configuration - the cron file '#{cron_input_filepath}' does not exist. Ensure a valid file exists at this location." unless
        File.exist?(cron_input_filepath)

      crontab_defn = File.readlines(cron_input_filepath)

      @job_defn_list = []
      crontab_defn.each do |cron_line|

        next if is_empty_line?(cron_line)
        next if is_comment_line?(cron_line)
        next if is_header_line?(cron_line)
        parts = cron_line.split('|')
        raise "Bad line in crontab definition: #{cron_line}" if parts.length < 5

        schedule = parts.shift.strip
        tz = parts.shift.strip
        running_user = parts.shift.strip
        unique_name = parts.shift.strip # Must not contain the | pipe character
        command = parts.join('|').chomp.strip
        raise "Bad line in crontab definition: #{cron_line}" if schedule.nil? or command.nil?
        @job_defn_list << {
          schedule: schedule,
          tz: tz,
          running_user: running_user,
          unique_name: unique_name,
          command: command
        }
      end
      @job_defn_list
    end

    def raise_error_if_repeating_cronjob_names
      names = job_defn_list.map {|item| item[:unique_name].downcase }
      repeating_names = names.select{ |name| names.count(name) > 1 }.uniq

      unless repeating_names.empty?
        msg = "The Unique Name column in the the cron file '#{cron_input_filepath}' " +
          "must be unique (case insensitive) but duplicates were detected: #{repeating_names.join(',')}."

        raise CronSyntaxError, msg
      end
    end

    def configure_support_for_plugin(plugin_attribute, plugin_xpath, doc)
        nodeset = doc.xpath(plugin_xpath)
        if installed_plugins.has_key? plugin_attribute
          nodeset.first.attributes['plugin'].value = "#{plugin_attribute}@#{installed_plugins[plugin_attribute]}"
        else
          nodeset.remove
        end
    end

    def installed_plugins
      @installed_plugins ||= JenkinsApi::Client::PluginManager.new(@client).list_installed
    end

    def bad_email_configuration_message
      "Bad configuration - the project configuration file at '#{project_config_filepath}' specifies " +
        "some email_recipients '#{project_config['email_recipients']}' but jenkins does not have the " +
        "'mailer' plugin installed, which is required. Here is a list of the installed plugins on the server: " +
        "\n\n#{installed_plugins.to_yaml}"
    end

    def initialize_private_config_file
      details = {}
      puts "What is your jenkins username?"
      details['jenkins_username'] = STDIN.gets.chomp
      puts "What is your jenkins password?"
      details['jenkins_password'] = STDIN.gets.chomp
      puts "What directory do you want to store cronjen data in? (Default is '#{default_data_dir}')"
      details['data_dir'] = STDIN.gets.chomp
      details['data_dir'] = default_data_dir if details['data_dir'].empty?
      Dir.mkdir(details['data_dir']) unless Dir.exist?(details['data_dir'])
      crons_dir = "#{details['data_dir']}/crons"
      Dir.mkdir(crons_dir) unless Dir.exist?(crons_dir)
      File.open(private_config_filepath, 'w') {|f| f.puts details.to_yaml }
      puts "Initialized a configuration file for you at '#{private_config_filepath}'"
    end

    def initialize_project_config_file
      details = {}
      puts "What is your jenkins URL or IP Address?"
      details['jenkins_url'] = STDIN.gets.chomp
      puts "What do you want to prefix you cronjen generated jobs with? (Default is no prefix)"
      details['user_defined_job_prefix'] = STDIN.gets.chomp
      details['jenkins_api_client_log_filepath'] = default_jenkins_api_client_log_filepath
      begin
        puts "What is the ssh command jenkins will use to connect to target servers? (Must be filled in)"
        details['ssh_command'] = STDIN.gets.chomp
      end while details['ssh_command'].empty?
      puts "What email address will receive notifications relating to jobs? (Default is empty, requires mailer plugin to be installed)"
      details['email_recipients'] = STDIN.gets.chomp
      puts "How runs of a job do you wish to keep logs for? (Default is 14)"
      details['log_num_to_keep'] = STDIN.gets.chomp
      details['log_num_to_keep'] = 14 if details['log_num_to_keep'].empty?
      File.open(project_config_filepath, 'w') {|f| f.puts details.to_yaml }
      puts "Initialized a project configuration file at '#{project_config_filepath}'"
    end

    def default_data_dir
      "#{Dir.home}/cronjen_data"
    end

    def default_jenkins_api_client_log_filepath
      "#{Dir.tmpdir}/ruby-jenkins-api-client.log"
    end

    def inventory
      @inventory ||= YAML.load_file(inventory_filepath)
    end

    def inventory_item
      inventory[@inventory_key]
    end

    def initialize_client
      @client = jenkins_api_client_class.new(:server_ip => config['jenkins_url'],
        :username => config['jenkins_username'], :password => config['jenkins_password'])
    end

    def jenkins_api_client_class
      if ENV['CRONJEN_ENV'] == 'test'
        CronjenTestJenkinsApiClient
      else
        JenkinsApi::Client
      end
    end

    def initialize_logger
      @client.logger = Logger.new(config['jenkins_log_filepath'], 10, 1024000)
    end

    def app_root_filepath
      @app_root_filepath ||= File.expand_path('../../../', __FILE__)
    end

    def test_root_filepath
      @test_root_filepath ||= File.expand_path('../../../spec/files', __FILE__)
    end

    def inventory_filepath
      "#{data_dirpath}/inventory.yml"
    end

    def config
      return @config if @config
      # This load ordering allows private config to override project config
      @config = {}.merge(project_config)
      @config.merge!(private_config)
      @config
    end

    def private_config
      @private_config ||= YAML.load_file(private_config_filepath)
    end

    def project_config
      @project_config ||= YAML.load_file(project_config_filepath)
    end

    def private_config_filepath
      if ENV['CRONJEN_ENV'] == 'test'
        "#{test_root_filepath}/private_config.yml"
      else
        "#{app_root_filepath}/private_config.yml"
      end
    end

    def data_dirpath
      File.absolute_path(private_config['data_dir'])
    end

    def project_config_filepath
      "#{data_dirpath}/project_config.yml"
    end

    def job_prefix
      text = ''
      unless config['user_defined_job_prefix'].to_s.empty?
        text << "#{config['user_defined_job_prefix']} - "
      end
      text << "#{inventory_item['target_host_url']}"
      text
    end

    def cron_input_filepath
      "#{data_dirpath}/crons/#{inventory_item['cron_filename']}"
    end

    def template_dirpath(template_name)
      "#{app_root_filepath}/templates/#{template_name}.crjn"
    end

    def is_comment_line?(line)
      /^\s*#/.match(line)
    end

    def is_header_line?(line)
      /^\s*schedule/.match(line.downcase)
    end

    def is_empty_line?(line)
      /^\s*$/.match(line.downcase)
    end

    def available_commands
      ['init', 'install', 'list', 'clear']
    end

    def two_arg_commands
      ['install', 'list', 'clear']
    end

    def fail_if_bad_configuration_or_usage
      raise ConfigError, "Bad configuration - a private configuration file was not found at '#{private_config_filepath}'. Ensure a valid file exists at this location by running: cronjen init" unless
        File.exist?(private_config_filepath)

      raise ConfigError, "Bad configuration - a project configuration file was not found at '#{project_config_filepath}'. Ensure a valid file exists at this location by running: cronjen init" unless
        File.exist?(project_config_filepath)

      raise UsageError, "Bad usage - the command '#{@command}' was supplied. Available commands are #{available_commands.join(',')}" unless
        available_commands.include? @command.to_s

      raise ConfigError, "Bad configuration - the inventory file '#{inventory_filepath}' does not exist. Ensure a valid file exists at this location." unless
        File.exist?(inventory_filepath)

      raise ConfigError, "Bad configuration - the inventory file is empty." if
        File.zero?(inventory_filepath)

      raise UsageError, "Bad usage - the way to invoke this command is - cronjen [install|list|clear] inventory_key. Available inventories are \n\t#{inventory.keys.join("\n\t")}" if
        @inventory_key.to_s.empty?

      raise ConfigError, "Bad configuration - the inventory key '#{inventory_item}' was supplied. Available inventories are \n\t#{inventory.keys.join("\n\t")}" unless
        inventory.keys.include? @inventory_key
    end

  end

end
