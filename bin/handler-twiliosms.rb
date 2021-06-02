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
         description: 'Twilio sid'
         short:       '-S SID',
         long:        '--sid SID'

  option :token,
         description: 'Twilio token'
         short:       '-T TOKEN',
         long:        '--token TOKEN'

  option :from_number,
         description: 'Twilio from number'
         short:       '-F NUMBER',
         long:        '--fromnumber NUMBER'


  option :recipients,
         description: 'Twilio recipients',
         short:       '-r RECIPIENT[,RECIPIENT...]',
         long:        '--recipients RECIPIENT[,RECIPIENT...]',
         proc:        proc { |v| v.upcase.split(',') },

  option :disableok,
         description: 'Disable ok',
         long: '--disableok',
         boolean: true,
         default: true

    #account_sid = settings['twiliosms']['sid']
    #auth_token = settings['twiliosms']['token']
    #from_number = settings['twiliosms']['number']
    #candidates = settings['twiliosms']['recipients']
    #short = settings['twiliosms']['short'] || false
    #disable_ok = settings['twiliosms']['disableOk'] || false


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
  endmi

  def event_match?(candidate)
    matching = false
    sensu_role_all = candidate['sensu_roles'].include?('all')
    puts " sensu_roles includes all: #{sensu_role_all}" if config[:verbose]
    matching ||= sensu_role_all
    keepalive_check = @event['check']['name'].eql?('keepalive')
    sensu_role_keepalive = candidate['sensu_roles'].include?('keepalive')
    puts " matching keepalive: #{(sensu_role_keepalive && keepalive_check)}" if config[:verbose]
    matching ||= (sensu_role_keepalive && keepalive_check)
    matching_subscribers = (@event['check']['subscribers'] &&
          !(candidate['sensu_roles'] & @event['check']['subscribers']).empty?)
    matching_subscribers ||= false
    puts " matching_subscribers: #{matching_subscribers}" if config[:verbose]
    matching ||= matching_subscribers
    matching_checkname = candidate['sensu_checks'].include?(check_name)
    puts " matching_checkname: #{matching_checkname}" if config[:verbose]
    matching || matching_checkname
  end

  def handle
    account_sid = config[:sid]
    auth_token = config[:token]
    from_number = config[:from_number]
    candidates = config[:recipients]
    short = false
    disable_ok = config[:disableok]

    return if @event['action'].eql?('resolve') && disable_ok

    raise 'Please define a valid Twilio authentication set to use this handler' unless account_sid && auth_token && from_number
    raise 'Please define a valid set of SMS recipients to use this handler' if candidates.nil? || candidates.empty?

    puts "Check: #{@event['check']}" if config[:verbose]
    puts "Check Status: #{check_status}" if config[:verbose]
    recipients = []
    candidates.each do |mobile, candidate|
      puts "Mobile: #{mobile} Config:#{candidate}" if config[:verbose]

      ##
      # Match event subsciption and/or check name using event_match? method
      #  and require requested level  <= check_status:
      #    sensu_level == 0  Matches all status
      #    sensu_level == 1  Matches warnings+critical+unknown
      #    sensu_level == 2  Matches critical+unknown
      #    sensu_level == 3  Matches unknown
      next unless event_match?(candidate) && (candidate['sensu_level'] <= check_status)

      puts "Send text to: #{mobile}" if config[:verbose]
      recipients << mobile
    end
    message = if short
                "Sensu #{action_to_string}: #{output}"
              else
                "Sensu #{action_to_string}: Status: #{check_status} :: #{short_name} (#{address}) #{output}"
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
