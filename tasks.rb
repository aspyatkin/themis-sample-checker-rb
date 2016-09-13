require 'sidekiq'
require 'themis/finals/checker/result'
require 'time_difference'
require 'net/http'
require 'json'
require './utils'
require 'raven/base'

config_module_name = ENV['THEMIS_FINALS_CHECKER_MODULE'] || ::File.join(
  Dir.pwd,
  'checker.rb'
)
require config_module_name

$logger = get_logger

::Sidekiq.default_worker_options = { 'retry' => 0 }

::Sidekiq.configure_server do |config|
  config.redis = {
    url: "redis://#{ENV['REDIS_HOST']}:#{ENV['REDIS_PORT']}/#{ENV['REDIS_DB']}"
  }

  config.on(:startup) do
    $logger.info "Starting queue process, instance #{ENV['QUEUE_INSTANCE']}"
  end
  config.on(:quiet) do
    $logger.info 'Got USR1, stopping further job processing...'
  end
  config.on(:shutdown) do
    $logger.info 'Got TERM, shutting down process...'
  end
end

::Sidekiq.configure_client do |config|
  config.redis = {
    url: "redis://#{ENV['REDIS_HOST']}:#{ENV['REDIS_PORT']}/#{ENV['REDIS_DB']}"
  }
end

$raven_enabled = !ENV['SENTRY_DSN'].nil?

if $raven_enabled
  ::Raven.configure do |config|
    config.dsn = ENV['SENTRY_DSN']
    config.ssl_verification = false
    config.logger = $logger
    config.async = lambda { |event|
      ::Thread.new { ::Raven.send_event(event) }
    }
  end
end

class Push
  include ::Sidekiq::Worker

  def internal_push(endpoint, flag, adjunct, metadata)
    result = ::Themis::Finals::Checker::Result::INTERNAL_ERROR
    updated_adjunct = adjunct
    begin
      result, updated_adjunct = push(endpoint, flag, adjunct, metadata)
    rescue Interrupt
      raise
    rescue Exception => e
      if $raven_enabled
        ::Raven.capture_exception e
      end
      $logger.error e.message
      e.backtrace.each { |line| $logger.error line }
    end

    return result, updated_adjunct
  end

  def perform(job_data)
    params = job_data['params']
    metadata = job_data['metadata']
    timestamp_created = ::DateTime.iso8601 metadata['timestamp']
    timestamp_delivered = ::DateTime.now

    status, updated_adjunct = internal_push(
      params['endpoint'],
      params['flag'],
      ::Base64.urlsafe_decode64(params['adjunct']),
      metadata
    )

    timestamp_processed = ::DateTime.now

    job_result = {
      status: status,
      flag: params['flag'],
      adjunct: ::Base64.urlsafe_encode64(updated_adjunct)
    }

    delivery_time = ::TimeDifference.between(
      timestamp_created,
      timestamp_delivered
    ).in_seconds
    processing_time = ::TimeDifference.between(
      timestamp_delivered,
      timestamp_processed
    ).in_seconds

    log_message = \
      'PUSH flag `%s` /%d to `%s`@`%s` (%s) - status %s, adjunct `%s` '\
      '[delivery %.2fs, processing %.2fs]' % [
        params['flag'],
        metadata['round'],
        metadata['service_name'],
        metadata['team_name'],
        params['endpoint'],
        ::Themis::Finals::Checker::Result.key(status),
        job_result[:adjunct],
        delivery_time,
        processing_time
      ]

    if $raven_enabled
      short_log_message = \
        'PUSH `%s...` /%d to `%s` - status %s' % [
          params['flag'][0..7],
          metadata['round'],
          metadata['team_name'],
          ::Themis::Finals::Checker::Result.key(status)
        ]

      raven_data = {
        level: 'info',
        tags: {
          tf_operation: 'push',
          tf_status: ::Themis::Finals::Checker::Result.key(status).to_s,
          tf_team: metadata['team_name'],
          tf_service: metadata['service_name'],
          tf_round: metadata['round']
        },
        extra: {
          endpoint: params['endpoint'],
          flag: params['flag'],
          adjunct: job_result[:adjunct],
          delivery_time: delivery_time,
          processing_time: processing_time
        }
      }

      ::Raven.capture_message short_log_message, raven_data
    end

    $logger.error log_message

    uri = URI(job_data['report_url'])

    req = ::Net::HTTP::Post.new(uri)
    req.body = job_result.to_json
    req.content_type = 'application/json'
    req[ENV['THEMIS_FINALS_AUTH_TOKEN_HEADER']] = issue_checker_token

    res = ::Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(req)
    end

    $logger.error res.value
  end
end

class Pull
  include ::Sidekiq::Worker

  def internal_pull(endpoint, flag, adjunct, metadata)
    result = ::Themis::Finals::Checker::Result::INTERNAL_ERROR
    begin
      result = pull(endpoint, flag, adjunct, metadata)
    rescue Interrupt
      raise
    rescue Exception => e
      if $raven_enabled
        ::Raven.capture_exception e
      end
      $logger.error e.message
      e.backtrace.each { |line| $logger.error line }
    end

    result
  end

  def perform(job_data)
    params = job_data['params']
    metadata = job_data['metadata']
    timestamp_created = ::DateTime.iso8601 metadata['timestamp']
    timestamp_delivered = ::DateTime.now

    status = internal_pull(
      params['endpoint'],
      params['flag'],
      ::Base64.urlsafe_decode64(params['adjunct']),
      metadata
    )

    timestamp_processed = ::DateTime.now

    job_result = {
      request_id: params['request_id'],
      status: status
    }

    delivery_time = ::TimeDifference.between(
      timestamp_created,
      timestamp_delivered
    ).in_seconds
    processing_time = ::TimeDifference.between(
      timestamp_delivered,
      timestamp_processed
    ).in_seconds

    log_message = \
      'PULL flag `%s` /%d from `%s`@`%s` (%s) with adjunct `%s` - status %s '\
      '[delivery %.2fs, processing %.2fs]' % [
        params['flag'],
        metadata['round'],
        metadata['service_name'],
        metadata['team_name'],
        params['endpoint'],
        params['adjunct'],
        ::Themis::Finals::Checker::Result.key(status),
        delivery_time,
        processing_time
      ]

    if $raven_enabled
      short_log_message = \
        'PULL `%s...` /%d from `%s` - status %s' % [
          params['flag'][0..7],
          metadata['round'],
          metadata['team_name'],
          ::Themis::Finals::Checker::Result.key(status)
        ]

      raven_data = {
        level: 'info',
        tags: {
          tf_operation: 'pull',
          tf_status: ::Themis::Finals::Checker::Result.key(status).to_s,
          tf_team: metadata['team_name'],
          tf_service: metadata['service_name'],
          tf_round: metadata['round']
        },
        extra: {
          endpoint: params['endpoint'],
          flag: params['flag'],
          adjunct: params['adjunct'],
          delivery_time: delivery_time,
          processing_time: processing_time
        }
      }

      ::Raven.capture_message short_log_message, raven_data
    end

    $logger.info log_message

    uri = URI(job_data['report_url'])

    req = ::Net::HTTP::Post.new(uri)
    req.body = job_result.to_json
    req.content_type = 'application/json'
    req[ENV['THEMIS_FINALS_AUTH_TOKEN_HEADER']] = issue_checker_token

    res = ::Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(req)
    end

    $logger.error res.value
  end
end
