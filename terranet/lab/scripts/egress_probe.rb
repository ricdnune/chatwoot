# Egress probe for the Terranet lab. Run:  terranet/lab/lab.sh rails runner terranet/lab/scripts/egress_probe.rb
# It replaces RestClient.post with a recorder (no network is attempted) and exercises every
# server-side call that targets Chatwoot-managed hosts, printing destination + payload KEY NAMES only
# (never values), so the output can be pasted into the audit without leaking identifiers.
require 'json'

CAPTURED = []
module RestClient
  def self.post(url, payload = nil, headers = {})
    body = JSON.parse(payload) rescue {}
    CAPTURED << { url: url, keys: body.keys.sort, headers: headers.keys }
    '{}'
  end
end

def run(label)
  CAPTURED.clear
  yield
  puts "#{label}:"
  puts '  (no outbound call)' if CAPTURED.empty?
  CAPTURED.each { |c| puts "  POST #{c[:url]}\n    payload keys: #{c[:keys].join(', ')}" }
end

puts "DISABLE_TELEMETRY=#{ENV['DISABLE_TELEMETRY'].inspect}  ENABLE_PUSH_RELAY_SERVER=#{ENV['ENABLE_PUSH_RELAY_SERVER'].inspect}  RAILS_ENV=#{Rails.env}"
run('ChatwootHub.sync_with_hub (daily version check, production only job)') { ChatwootHub.sync_with_hub }
run('ChatwootHub.emit_event') { ChatwootHub.emit_event('probe', { a: 1 }) }
run('ChatwootHub.register_instance (onboarding "subscribe to updates")') { ChatwootHub.register_instance('c', 'n', 'e@example.invalid') }
run('ChatwootHub.send_push (mobile push relay)') { ChatwootHub.send_push({ to: 'x' }) }

puts "Internal::CheckNewVersionsJob scheduled only when Rails.env.production?: #{Internal::CheckNewVersionsJob.instance_method(:perform).source_location.join(':')}"
