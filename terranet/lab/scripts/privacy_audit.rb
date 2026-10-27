# Runs INSIDE the `audit` container (RAILS_ENV=production against the disposable chatwoot_prodsim DB, synthetic data
# only). Exercises every known path that could reach a Chatwoot or third-party avatar host, executing jobs inline.
# Network observation is done outside by lab.sh audit-egress (dns-sink query log + egress-sink packet log).
require 'socket'

# Inline execution, also for jobs scheduled with `set(wait:)` (the stock inline adapter refuses those).
class TerranetImmediateAdapter < ActiveJob::QueueAdapters::InlineAdapter
  def enqueue_at(job, _timestamp)
    enqueue(job)
  end
end
ActiveJob::Base.queue_adapter = TerranetImmediateAdapter.new
puts "env=#{Rails.env} enterprise=#{ChatwootApp.enterprise?.inspect} privacy=#{Terranet::Privacy.enabled?} " \
     "gravatar_disabled=#{ENV['DISABLE_GRAVATAR'].present?} push_relay=#{ENV['ENABLE_PUSH_RELAY_SERVER'].inspect}"

def step(label)
  yield
  puts "  ok   #{label}"
rescue StandardError => e
  puts "  err  #{label}: #{e.class}: #{e.message.to_s[0, 90]}"
end

# GlobalConfigService persists DISABLE_GRAVATAR from the env into installation_configs the first time it is read, so a
# control run without the env would still see it disabled; clear the row so the control reflects stock behaviour.
if ENV['DISABLE_GRAVATAR'].blank?
  InstallationConfig.where(name: 'DISABLE_GRAVATAR').destroy_all
  GlobalConfig.clear_cache
end
run_id = SecureRandom.hex(4) # the DB persists between runs; keep unique fields unique
account = Account.find_or_create_by!(name: 'Audit Synthetic')
user = User.find_or_initialize_by(email: 'audit-agent@example.invalid')
user.update!(name: 'Audit Agent', password: 'Audit-Pass-1!', password_confirmation: 'Audit-Pass-1!') if user.new_record?
AccountUser.find_or_create_by!(account: account, user: user) { |au| au.role = :administrator }

step('daily trigger -> version check (production path)') { Internal::TriggerDailyScheduledItemsJob.perform_now }
step('version check job direct') { Internal::CheckNewVersionsJob.perform_now }
step('ChatwootHub.register_instance') { ChatwootHub.register_instance('Audit Co', 'Audit Owner', 'owner@example.invalid') }
step('ChatwootHub.emit_event') { ChatwootHub.emit_event('audit', { a: 1 }) }
step('ChatwootHub.send_push') { ChatwootHub.send_push({ to: 'synthetic-token' }) }
step('gravatar lookup (contact saved with an email)') do
  Contact.create!(account: account, name: 'Audit Gravatar', email: "audit-gravatar-#{run_id}@example.invalid")
end
step('company favicon fetch') do
  company = Company.create!(account: account, name: 'Audit Customer', domain: "audit-#{run_id}.example")
  Avatar::AvatarFromFaviconJob.perform_now(company)
end
step('push relay via notification service') do
  channel = Channel::WebWidget.create!(account: account, website_url: 'https://audit.example')
  inbox = Inbox.create!(account: account, name: 'Audit Inbox', channel: channel)
  contact = Contact.create!(account: account, name: 'Audit Contact', email: "audit-contact-#{run_id}@example.invalid")
  contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.uuid)
  conversation = Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  user.notification_subscriptions.create!(subscription_type: 'fcm', identifier: "synthetic-token-#{run_id}", subscription_attributes: { push_token: 'synthetic-token' })
  notification = Notification.create!(account: account, user: user, notification_type: 'conversation_creation', primary_actor: conversation)
  Notification::PushNotificationService.new(notification: notification).perform
end

if ENV['AUDIT_DIRECT_IP'] == '1'
  step('direct IP connection (203.0.113.9:443, no DNS)') do
    Socket.tcp('203.0.113.9', 443, connect_timeout: 2) { |s| s.close }
  rescue SystemCallError, IO::TimeoutError
    nil # a refused/timed-out connect is fine: the point is that the SYN reached egress-sink
  end
end
