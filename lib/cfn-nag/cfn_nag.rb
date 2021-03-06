require_relative 'custom_rule_loader'
require_relative 'rule_registry'
require_relative 'profile_loader'
require_relative 'template_discovery'
require_relative 'result_view/simple_stdout_results'
require_relative 'result_view/json_results'
require 'cfn-model'
require 'logging'

class CfnNag
  def initialize(profile_definition: nil,
                 rule_directory: nil)
    @rule_directory = rule_directory
    @custom_rule_loader = CustomRuleLoader.new(rule_directory: rule_directory)
    @profile_definition = profile_definition
  end

  ##
  # Given a file or directory path, emit aggregate results to stdout
  #
  # Return an aggregate failure count (for exit code usage)
  #
  def audit_aggregate_across_files_and_render_results(input_path:,
                                                      output_format:'txt')
    aggregate_results = audit_aggregate_across_files input_path: input_path

    render_results(aggregate_results: aggregate_results,
                   output_format: output_format)

    aggregate_results.inject(0) do |total_failure_count, results|
      total_failure_count + results[:file_results][:failure_count]
    end
  end

  ##
  # Given a file or directory path, return aggregate results
  #
  def audit_aggregate_across_files(input_path:)
    templates = TemplateDiscovery.new.discover_templates(input_path)
    aggregate_results = []
    templates.each do |template|
      aggregate_results << {
        filename: template,
        file_results: audit(cloudformation_string: IO.read(template))
      }
    end
    aggregate_results
  end

  ##
  # Given cloudformation json/yml, run all the rules against it
  #
  # Return a hash with failure count
  #
  def audit(cloudformation_string:)
    stop_processing = false
    violations = []

    begin
      cfn_model = CfnParser.new.parse cloudformation_string
    rescue ParserError => parser_error
      violations << Violation.new(id: 'FATAL',
                                  type: Violation::FAILING_VIOLATION,
                                  message: parser_error.to_s)
      stop_processing = true
    end

    violations += @custom_rule_loader.execute_custom_rules(cfn_model) unless stop_processing == true

    violations = filter_violations_by_profile violations unless stop_processing == true

    {
      failure_count: Violation.count_failures(violations),
      violations: violations
    }
  end

  def self.configure_logging(opts)
    logger = Logging.logger['log']
    if opts[:debug]
      logger.level = :debug
    else
      logger.level = :info
    end

    logger.add_appenders Logging.appenders.stdout
  end

  private

  def filter_violations_by_profile(violations)
    profile = nil
    unless @profile_definition.nil?
      profile = ProfileLoader.new(@custom_rule_loader.rule_definitions).load(profile_definition: @profile_definition)
    end

    violations.reject do |violation|
      not profile.nil? and not profile.execute_rule?(violation.id)
    end
  end

  def render_results(aggregate_results:,
                     output_format:)
    results_renderer(output_format).new.render(aggregate_results)
  end

  def results_renderer(output_format)
    registry = {
      'txt' => SimpleStdoutResults,
      'json' => JsonResults
    }
    registry[output_format]
  end
end
