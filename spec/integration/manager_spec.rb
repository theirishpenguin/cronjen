require 'spec_helper'
require_relative '../../lib/cronjen/manager'
require 'ostruct'

describe "Cronjen::Manager" do

  # This is only used to initialize the client, after that point it is usually
  # replaced with a instance double, so that methods that do not exist are not
  # accidentally stubbed
  class CronjenTestJenkinsApiClient
    def initialize(options)
      @initialization_options = options
    end
    def logger=(some_logger)
      @logger = some_logger
    end
  end

  let(:installed_plugins) do
    {"throttle-concurrents"=>"9.8.7", "mailer"=>"6.5", "timestamper"=>"1.7.3"}
  end

  describe "list command" do
    let(:command_key) { 'list' }
    let(:inventory_key) { 'example-machine-1-simple-command'}
    let(:manager) { Cronjen::Manager.new(command_key, inventory_key) }

    let(:job_list) do
      ["Spec - Cronjen - Fake Machine 1 - Fake Task A"]
    end

    let(:job_details) do
      {
        "property" => [
            {
              "parameterDefinitions" => [
                {
                  "defaultParameterValue" => {
                    "name" => "host",
                    "value" => "foo.example.com"
                  },
                  "description" => "Host on which to run the job\n",
                  "name" => "host",
                  "type" => "StringParameterDefinition"
                },
                {
                  "defaultParameterValue" => {
                    "name" => "loginuser",
                    "value" => "jenny"
                  },
                  "description" => "User on host that will run the job",
                  "name" => "loginuser",
                  "type" => "StringParameterDefinition"
                },
                {
                  "defaultParameterValue" => {
                    "name" => "command",
                    "value" => "cd /path/to/some/dir && unbuffer ./bin/foo.rb  2>&1 | tee /path/to/some/logs/logs/foo.log"
                  },
                  "description" => "Command to run",
                  "name" => "command",
                  "type" => "StringParameterDefinition"
                },
                {
                  "defaultParameterValue" => {
                    "name" => "cronjen_plus_command",
                    "value" => "CRONJEN_PLUS:{\"type\":\"aws_fire_and_forget\",\"region\":\"us-west-2\", \"cmd\": \"cd /path/to/some/dir && unbuffer ./bin/foo.rb  2>&1 | tee /path/to/some/logs/logs/foo.log\"}"
                  },
                  "description" => "Cronjen Plus command",
                  "name" => "cronjen_plus_command",
                  "type" => "StringParameterDefinition"
                }
              ]
            }
          ]
      }
    end

    let(:partial_job_xml) do
      <<-EOF
        <?xml version="1.0" encoding="UTF-8"?>
        <project>
          <triggers>
            <hudson.triggers.TimerTrigger>
              <spec>TZ=UTC
        2 2 * 31 2 *</spec>
            </hudson.triggers.TimerTrigger>
          </triggers>
        </project>
      EOF
    end

    let(:expected_output) do
      <<-EOF
The jenkins cron on the server now looks like:

# Schedule | Timezone | Running User | Unique Name | Command
        2 2 * 31 2 * | UTC | jenny | Spec - Cronjen - Fake Machine 1 - Fake Task A | CRONJEN_PLUS:{"type":"aws_fire_and_forget","region":"us-west-2", "cmd": "cd /path/to/some/dir && unbuffer ./bin/foo.rb  2>&1 | tee /path/to/some/logs/logs/foo.log"}
      EOF
    end

    it "should create a new instance" do
      jenkins_api_job = instance_double("JenkinsApi::Client::Job",
        :list => job_list, :list_details => job_details, :get_config => partial_job_xml)
      jenkins_api_client = instance_double("JenkinsApi::Client", :job => jenkins_api_job)

      manager.instance_variable_set(:@client, jenkins_api_client)

      expect{ manager.execute_command }.to output(expected_output).to_stdout
    end
  end

  describe "install command - simple commmand test" do
    let(:inventory_key) { 'example-machine-1-simple-command'}
    let(:manager) { Cronjen::Manager.new(command_key, inventory_key) }

    let(:command_key) { 'install' }

    it "should generate the correct job xml " do
      jenkins_api_job = instance_double("JenkinsApi::Client::Job")
      stub_objects_for_install_test(manager, jenkins_api_job)

      expected_job_xml = File.read(File.expand_path('../../../spec/files/expected_results/machine-1-example-test--install.xml', __FILE__))

      expect(jenkins_api_job).to receive(:create).with("Spec - Cronjen - machine-1.example.com - Simple Command Test", expected_job_xml)
      manager.execute_command
    end
  end

  describe "install command - instance starter test" do
    let(:inventory_key) { 'example-machine-2-instance-starter'}
    let(:manager) { Cronjen::Manager.new(command_key, inventory_key) }

    let(:command_key) { 'install' }

    it "should generate the correct job xml " do
      jenkins_api_job = instance_double("JenkinsApi::Client::Job")
      stub_objects_for_install_test(manager, jenkins_api_job)

      expected_job_xml = File.read(File.expand_path('../../../spec/files/expected_results/machine-2-example-test--install.xml', __FILE__))

      expect(jenkins_api_job).to receive(:create).with("Spec - Cronjen - machine-2.example.com - Instance Starter Test", expected_job_xml)
      manager.execute_command
    end
  end

  describe "install command - fire and forget test" do
    let(:inventory_key) { 'example-machine-3-fire-and-forget'}
    let(:manager) { Cronjen::Manager.new(command_key, inventory_key) }

    let(:command_key) { 'install' }

    it "should generate the correct job xml " do
      jenkins_api_job = instance_double("JenkinsApi::Client::Job")
      stub_objects_for_install_test(manager, jenkins_api_job)

      expected_job_xml = File.read(File.expand_path('../../../spec/files/expected_results/machine-3-example-test--install.xml', __FILE__))

      expect(jenkins_api_job).to receive(:create).with("Spec - Cronjen - machine-3.example.com - Fire and Forget Test", expected_job_xml)
      manager.execute_command
    end
  end

  def stub_objects_for_install_test(manager, jenkins_api_job)
      jenkins_api_client = instance_double("JenkinsApi::Client", :job => jenkins_api_job)

      allow(manager).to receive(:silent_clear).and_return(nil)
      allow(manager).to receive(:list).and_return(nil)
      allow(manager).to receive(:installed_plugins).and_return(installed_plugins)

      manager.instance_variable_set(:@client, jenkins_api_client)
  end
end
