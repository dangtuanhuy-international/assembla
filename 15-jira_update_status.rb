# frozen_string_literal: true

load './lib/common.rb'
load './lib/users-assembla.rb'

@assembla_status_to_jira = {}
JIRA_API_STATUSES.split(',').each do |status|
  from, to = status.split(':')
  @assembla_status_to_jira[from.downcase] = to || from
end

# Assembla tickets
tickets_csv = "#{OUTPUT_DIR_ASSEMBLA}/tickets.csv"
@tickets_assembla = csv_to_array(tickets_csv)

# --- Filter by date if TICKET_CREATED_ON is defined --- #
tickets_created_on = get_tickets_created_on

if tickets_created_on
  puts "\nFilter newer than: #{tickets_created_on}"
  @tickets_assembla.select! { |item| item_newer_than?(item, tickets_created_on) }
end

# Collect ticket statuses
@assembla_statuses = {}
@extra_summary_types = {}
@tickets_assembla.each do |ticket|
  status = ticket['status']
  summary = ticket['summary']
  if @assembla_statuses[status].nil?
    @assembla_statuses[status] = 0
  else
    @assembla_statuses[status] += 1
  end
  if summary.match(/^([A-Z]*):/)
    t = summary.sub(/:.*$/, '\1')
    @extra_summary_types[t] = true if !ASSEMBLA_TYPES_EXTRA.include?(t.downcase) && @extra_summary_types[t].nil?
  end
end

@total_assembla_tickets = @tickets_assembla.length
puts "\nTotal Assembla tickets: #{@total_assembla_tickets}"

puts "\nAssembla ticket statuses:"
@assembla_statuses.keys.each do |key|
  puts "* #{key}: #{@assembla_statuses[key]}"
end

if @extra_summary_types.length.positive?
  puts "\nExtra statuses detected in the summary (ignored): #{@extra_summary_types.length}"
  @extra_summary_types.keys.sort.each do |type|
    puts "* #{type}"
  end
end

# Sanity check just in case
@missing_statuses = []
@assembla_statuses.keys.each do |key|
  @missing_statuses << key unless @assembla_status_to_jira[key.downcase]
end

if @missing_statuses.length.positive?
  puts "\nSanity check => NOK"
  puts "The following statuses are missing:"
  @missing_statuses.each do |status|
    puts "* #{status}"
  end
  goodbye("Update JIRA_API_STATUSES in .env file and create JIRA statuses if needed")
end
puts "Sanity check => OK"

# Jira tickets
resolutions_jira_csv = "#{OUTPUT_DIR_JIRA}/jira-resolutions.csv"
statuses_jira_csv = "#{OUTPUT_DIR_JIRA}/jira-statuses.csv"
tickets_jira_csv = "#{OUTPUT_DIR_JIRA}/jira-tickets.csv"

@resolutions_jira = csv_to_array(resolutions_jira_csv)
@statuses_jira = csv_to_array(statuses_jira_csv)
@tickets_jira = csv_to_array(tickets_jira_csv)

@jira_resolution_name_to_id = {}
puts "\nJira ticket resolutions:"
@resolutions_jira.each do |resolution|
  @jira_resolution_name_to_id[resolution['name'].downcase] = resolution['id']
  puts "* #{resolution['id']}: #{resolution['name']}"
end

@jira_status_name_to_id = {}
puts "\nJira ticket statuses:"
@statuses_jira.each do |status|
  @jira_status_name_to_id[status['name'].downcase] = status['id']
  puts "* #{status['id']}: #{status['name']}"
end

# Convert assembla_ticket_id to jira_ticket
@assembla_id_to_jira = {}
@jira_id_to_login = {}
@tickets_jira.each do |ticket|
  jira_id = ticket['jira_ticket_id']
  assembla_id = ticket['assembla_ticket_id']
  @assembla_id_to_jira[assembla_id] = jira_id
  @jira_id_to_login[jira_id] = ticket['reporter_name']
end

# GET /rest/api/2/issue/{issueIdOrKey}/transitions
def jira_get_transitions(issue_id)
  result = nil
  user_login = @jira_id_to_login[issue_id]
  user_login.sub!(/@.*$/,'')
  user_email = @user_login_to_email[user_login]
  headers = headers_user_login(user_login, user_email)
  url = "#{URL_JIRA_ISSUES}/#{issue_id}/transitions"
  begin
    response = RestClient::Request.execute(method: :get, url: url, headers: headers)
    result = JSON.parse(response.body)
    puts "\nGET #{url} => OK"
  rescue RestClient::ExceptionWithResponse => e
    rest_client_exception(e, 'GET', url)
  rescue RestClient::Exception => e
    rest_client_exception(e, 'GET', url)
  rescue => e
    puts "\nGET #{url} => NOK (#{e.message})"
  end
  if result.nil?
    nil
  else
    transitions = result['transitions']
    puts "\nJira ticket transitions:"
    transitions.each do |transition|
      puts "* #{transition['id']} '#{transition['name']}' =>  #{transition['to']['id']} '#{transition['to']['name']}'"
    end
    puts
    transitions
  end
end

# POST /rest/api/2/issue/{issueIdOrKey}/transitions
def jira_update_status(issue_id, status, counter)
  if status.casecmp('done').zero? || status.casecmp('invalid').zero?
    payload = {
      update: {},
      transition: {
        id: @transition_target_name_to_id['done'].to_i
      }
    }.to_json
    transition = {
      from: {
        id: @jira_status_name_to_id['to do'],
        name: 'to do'
      },
      to: {
        id: @jira_status_name_to_id['done'],
        name: 'done'
      }
    }
  elsif status.casecmp('new').zero?
    # Do nothing
    transition = {
      from: {
        id: @jira_status_name_to_id['to do'],
        name: 'to do'
      },
      to: {
        id: @jira_status_name_to_id['to do'],
        name: 'to do'
      }
    }
    return { transition: transition }
  elsif status.casecmp('in progress').zero?
    payload = {
      update: {},
      transition: {
        id: @transition_target_name_to_id['in progress'].to_i
      }
    }.to_json
    transition = {
      from: {
        id: @jira_status_name_to_id['to do'],
        name: 'to do'
      },
      to: {
        id: @jira_status_name_to_id['in progress'],
        name: 'in progress'
      }
    }
  else
    # TODO: Figure out how to deal with the other statuses: testable, blocked, ready for acceptance, etc.
    # For now just set them to 'in progress'
    payload = {
      update: {},
      transition: {
        id: @transition_target_name_to_id['in progress'].to_i
      }
    }.to_json
    transition = {
      from: {
        id: @jira_status_name_to_id['to do'],
        name: 'to do'
      },
      to: {
        id: @jira_status_name_to_id['in progress'],
        name: 'in progress'
      }
    }
  end

  result = nil
  user_login = @jira_id_to_login[issue_id]
  user_login.sub!(/@.*$/,'')
  user_email = @user_login_to_email[user_login]
  headers = headers_user_login(user_login, user_email)
  url = "#{URL_JIRA_ISSUES}/#{issue_id}/transitions"
  begin
    percentage = ((counter * 100) / @total_assembla_tickets).round.to_s.rjust(3)
    RestClient::Request.execute(method: :post, url: url, payload: payload, headers: headers)
    puts "#{percentage}% [#{counter}|#{@total_assembla_tickets}] POST #{url} '#{transition[:from][:name]}' to '#{transition[:to][:name]}' => OK"
    result = { transition: transition }
  rescue RestClient::ExceptionWithResponse => e
    rest_client_exception(e, 'POST', url, payload)
  rescue => e
    puts "#{percentage}% [#{counter}|#{@total_assembla_tickets}] POST #{url} #{payload.inspect} => NOK (#{e.message})"
  end
  if result
    # If the issue has been closed (done) we set the resolution to the appropriate value
    if status.casecmp('done').zero? || status.casecmp('invalid').zero?
      resolution_name = status.casecmp('invalid').zero? ? "Won't do" : 'Done'
      resolution_id = @jira_resolution_name_to_id[resolution_name.downcase].to_i
      payload = {
        update: {},
        fields: {
          resolution: {
            id: "#{resolution_id}"
          }
        }
      }.to_json
      url = "#{URL_JIRA_ISSUES}/#{issue_id}"
      begin
        RestClient::Request.execute(method: :put, url: url, payload: payload, headers: headers)
      rescue RestClient::ExceptionWithResponse => e
        rest_client_exception(e, 'PUT', url, payload)
      rescue => e
        puts "PUT #{url} resolution='#{resolution_name}' => NOK (#{e.message})"
      end
    end
  end
  result
end

first_id = @tickets_assembla.first['id']
goodbye('Cannot find first_id') unless first_id

issue_id = @assembla_id_to_jira[first_id]
goodbye("Cannot find issue_id, first_id='#{first_id}'") unless first_id

@transitions = jira_get_transitions(@assembla_id_to_jira[@tickets_assembla.first['id']])
goodbye("No transitions available, first_id='#{first_id}', issue_id=#{issue_id}") unless @transitions && @transitions

@transition_target_name_to_id = {}
@transitions.each do |transition|
  @transition_target_name_to_id[transition['to']['name'].downcase] = transition['id'].to_i
end

@jira_updates_tickets = []

@tickets_assembla.each_with_index do |ticket, index|
  assembla_ticket_id = ticket['id']
  assembla_ticket_status = ticket['status']
  jira_ticket_id = @assembla_id_to_jira[ticket['id']]
  result = jira_update_status(jira_ticket_id, assembla_ticket_status, index + 1)
  @jira_updates_tickets << {
    result: result.nil? ? 'NOK' : 'OK',
    assembla_ticket_id: assembla_ticket_id,
    assembla_ticket_status: assembla_ticket_status,
    jira_ticket_id: jira_ticket_id,
    jira_transition_from_id: result.nil? ? 0 : result[:transition][:from][:id],
    jira_transition_from_name: result.nil? ? 0 : result[:transition][:from][:name],
    jira_transition_to_id: result.nil? ? 0 : result[:transition][:to][:id],
    jira_transition_to_name: result.nil? ? 0 : result[:transition][:to][:name]
  }
end

puts "\nTotal updates: #{@jira_updates_tickets.length}"
updates_tickets_jira_csv = "#{OUTPUT_DIR_JIRA}/jira-tickets-status-updates.csv"
write_csv_file(updates_tickets_jira_csv, @jira_updates_tickets)
