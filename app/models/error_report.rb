require 'hoptoad_notifier'

##
# Processes a new error report.
#
# Accepts a hash with the following attributes:
#
# * <tt>:error_class</tt> - the class of error
# * <tt>:message</tt> - the error message
# * <tt>:backtrace</tt> - an array of stack trace lines
#
# * <tt>:request</tt> - a hash of values describing the request
# * <tt>:server_environment</tt> - a hash of values describing the server environment
#
# * <tt>:notifier</tt> - information to identify the source of the error report
#
class ErrorReport
  attr_reader :error_class, :message, :request, :server_environment, :api_key,
              :notifier, :user_attributes, :framework, :notice

  cattr_accessor :fingerprint_strategy do
    Fingerprint::Sha1
  end

  def initialize(xml_or_attributes)
    @attributes = xml_or_attributes
    @attributes = Hoptoad.parse_xml!(@attributes) if @attributes.is_a? String
    @attributes = @attributes.with_indifferent_access
    @attributes.each { |k, v| instance_variable_set(:"@#{k}", v) }
  end

  def rails_env
    rails_env = server_environment['environment-name']
    rails_env = 'development' if rails_env.blank?
    rails_env
  end

  def app
    @app ||= App.where(api_key: api_key).first
  end

  def backtrace
    @normalized_backtrace ||= Backtrace.find_or_create(@backtrace)
  end

  def generate_notice!
    return unless valid?
    return @notice if @notice

    make_notice
    error.notices << @notice
    cache_attributes_on_problem
    email_notification
    services_notification
    @notice
  end

  def make_notice
    @notice = Notice.new(
      message: message,
      error_class: error_class,
      backtrace: backtrace,
      request: request,
      server_environment: server_environment,
      notifier: notifier,
      user_attributes: user_attributes,
      framework: framework
    )
  end

  # Update problem cache with information about this notice
  def cache_attributes_on_problem
    # increment notice count
    message_digest = Digest::MD5.hexdigest(@notice.message)
    host_digest = Digest::MD5.hexdigest(@notice.host)
    user_agent_digest = Digest::MD5.hexdigest(@notice.user_agent_string)

    @problem = Problem.where("_id" => @error.problem_id).find_one_and_update(
      '$set' => {
        'app_name' => app.name,
        'environment' => @notice.environment_name,
        'error_class' => @notice.error_class,
        'last_notice_at' => @notice.created_at,
        'message' => @notice.message,
        'resolved' => false,
        'resolved_at' => nil,
        'where' => @notice.where,
        "messages.#{message_digest}.value" => @notice.message,
        "hosts.#{host_digest}.value" => @notice.host,
        "user_agents.#{user_agent_digest}.value" => @notice.user_agent_string,
      },
      '$inc' => {
        'notices_count' => 1,
        "messages.#{message_digest}.count" => 1,
        "hosts.#{host_digest}.count" => 1,
        "user_agents.#{user_agent_digest}.count" => 1,
      }
    )
  end

  def similar_count
    @similar_count ||= @problem.notices_count
  end

  # Send email notification if needed
  def email_notification
    return false unless app.emailable?
    return false unless app.email_at_notices.include?(similar_count)
    Mailer.err_notification(@notice).deliver
  rescue => e
    HoptoadNotifier.notify(e)
  end

  def should_notify?
    app.notification_service.notify_at_notices.include?(0) ||
      app.notification_service.notify_at_notices.include?(similar_count)
  end

  # Launch all notification define on the app associate to this notice
  def services_notification
    return true unless app.notification_service_configured? and should_notify?
    app.notification_service.create_notification(problem)
  rescue => e
    HoptoadNotifier.notify(e)
  end

  ##
  # Error associate to this error_report
  #
  # Can already exist or not
  #
  # @return [ Error ]
  def error
    @error ||= app.find_or_create_err!(
      error_class: error_class,
      environment: rails_env,
      fingerprint: fingerprint
    )
  end

  def valid?
    app.present?
  end

  def should_keep?
    app_version = server_environment['app-version'] || ''
    current_version = app.current_app_version
    return true unless current_version.present?
    return false if app_version.length <= 0
    Gem::Version.new(app_version) >= Gem::Version.new(current_version)
  end

  private

  def fingerprint
    @fingerprint ||= fingerprint_strategy.generate(notice, api_key)
  end
end
