#!/usr/bin/env ruby
#
# Sensu Handler: twilio
#
# This handler formats alerts as SMSes and sends them off to a pre-defined recipient.
#
# Copyright 2012 Panagiotis Papadomitsos <pj@ezgr.net>
#
# Released under the same terms as Sensu (the MIT license); see LICENSE
# for details.

require 'sensu-handler'
require 'twilio-ruby'
require 'rest-client'
require 'json'
require 'net/http'
require 'openssl'

class TwilioSMS < Sensu::Handler
  option :verbose,
         description: 'Verbose output',
         short: '-v',
         long: '--verbose',
         boolean: true,
         default: false

  option :disable_send,
         description: 'Disable send',
         long: '--disable_send',
         boolean: true,
         default: false

  option :sid,
         description: 'Twilio sid',
         short: '-S SID',
         long: '--sid SID'

  option :token,
         description: 'Twilio token',
         short: '-T TOKEN',
         long: '--token TOKEN'

  option :from_number,
         description: 'Twilio from number',
         short: '-F NUMBER',
         long: '--fromnumber NUMBER'

  option :url,
         description: 'Recipients url',
         short: '-ur URL',
         long: '--url URL'

  option :user,
         description: 'Recipinets url user',
         short: '-u USER',
         long: '--user USER'

  option :password,
         description: 'Recipinets url password',
         short: '-p PASSWORD',
         long: '--password PASSWORD'

  def short_name
    (@event['client']['name'] || 'unknown') + '/' + (@event['check']['name'] || 'unknown')
  end

  def output
    @event['check']['output'] || 'no check output'
  end

  def address
    @event['client']['address'] || 'unknown address'
  end

  def check_name
    @event['check']['name'] if @event.include? 'check'
  end

  def check_status
    check_status = @event['check']['status'] if @event.include? 'check'
    check_status || 3
  end

  def action_to_string
    @event['action'].eql?('resolve') ? 'RESOLVED' : 'ALERT'
  end

  def recipients
    uri = URI(config[:url].to_s)
    Net::HTTP.start(
      uri.host, uri.port,
      use_ssl: uri.scheme == 'https',
      verify_mode: OpenSSL::SSL::VERIFY_NONE
    ) do |http|
      request = Net::HTTP::Get.new uri.request_uri
      request.basic_auth config[:user], config[:password]
      response = http.request request # Net::HTTPResponse object
      JSON.parse(response.body)['current_on_call']
    end
  end

  def handle
    account_sid = config[:sid]
    auth_token = config[:token]
    from_number = config[:from_number]
    candidates = recipients
    short = false
    disable_ok = true

    return if @event['action'].eql?('resolve') && disable_ok

    raise 'Please define a valid Twilio authentication set to use this handler' unless account_sid && auth_token && from_number
    raise 'Please define a valid set of SMS recipients to use this handler' if candidates.nil? || candidates.empty?

    puts "Check: #{@event['check']}" if config[:verbose]
    puts "Check Status: #{check_status}" if config[:verbose]
    recipients = candidates
    check_name = @event['check']['name']] || 'unknown'
    client = @event['client']['name'] || 'unknown'
    incident_id = [source, @event['check']['name']].join('  ')
    message = if short
                "Sensu Shrt #{action_to_string}: #{output}"
              else
                "Sensu #{action_to_string} #{check_name} Status #{check_status} on #{client} #{output}."
              end

    message[157..message.length] = '...' if message.length > 160

    twilio = Twilio::REST::Client.new(account_sid, auth_token)
    recipients.each do |recipient|
      if config[:disable_send]
        puts "From: #{from_number} To: #{recipient} Body: #{message}"
      else
        begin
          twilio.api.account.messages.create(
            from: from_number,
            to: recipient,
            body: message
          )
          puts "Notified #{recipient} for #{action_to_string} via SMS"

          twilio.calls.create(
            twiml: "<Response><Say>#{message}</Say></Response>",
            to: recipient,
            from: from_number
          )
          puts "Notified #{recipient} for #{action_to_string} via Voice"
        rescue StandardError => e
          puts "Failure detected while using Twilio to notify on event: #{e.message}"
        end
      end
    end
  end
end
