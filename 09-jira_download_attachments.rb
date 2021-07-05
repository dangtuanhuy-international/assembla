# frozen_string_literal: true

load './lib/common.rb'

# Assembla attachments
users_assembla_csv = "#{OUTPUT_DIR_ASSEMBLA}/users.csv"
tickets_assembla_csv = "#{OUTPUT_DIR_ASSEMBLA}/tickets.csv"
attachments_assembla_csv = "#{OUTPUT_DIR_ASSEMBLA}/ticket-attachments.csv"

@users_assembla = csv_to_array(users_assembla_csv)
@tickets_assembla = csv_to_array(tickets_assembla_csv)
@attachments_assembla = csv_to_array(attachments_assembla_csv)

total_attachments = @attachments_assembla.length
puts "Total attachments: #{total_attachments}"

@jira_attachments = []

@assembla_id_to_login = {}
@users_assembla.each do |user|
  @assembla_id_to_login[user['id']] = user['login']
end

# --- Filter by date if TICKET_CREATED_ON is defined --- #
tickets_created_on = get_tickets_created_on

if tickets_created_on
  puts "Filter newer than: #{tickets_created_on}"
  attachments_initial = @attachments_assembla.length
  @attachments_assembla.select! do |attachment|
    # IMPORTANT: filter on create date of ticket to which the attachment belongs
    # and NOT the attachment
    ticket_id = attachment['ticket_id']
    ticket = @tickets_assembla.detect { |t| t['id'] == ticket_id }
    goodbye("cannot find ticket id='#{ticket_id}'") unless ticket
    item_newer_than?(ticket, tickets_created_on)
  end
  puts "Attachments: #{attachments_initial} => #{@attachments_assembla.length} ∆#{attachments_initial - @attachments_assembla.length}"
else
  puts "Attachments: #{@attachments_assembla.length}"
end

# IMPORTANT: Make sure that the attachments are ordered chronologically from first (oldest) to last (newest)
@attachments_assembla.sort! { |x, y| x['created_at'] <=> y['created_at'] }

@attachments_total = @attachments_assembla.length

@authorization = "Basic #{Base64.encode64(JIRA_API_ADMIN_USER + ':' + ENV['JIRA_API_ADMIN_PASSWORD'])}"

@attachments_assembla.each_with_index do |attachment, index|
  url = attachment['url']
  id = attachment['id']
  created_at = attachment['created_at']
  created_by = @assembla_id_to_login[attachment['created_by']]
  assembla_ticket_id = attachment['ticket_id']
  content_type = attachment['content_type']
  counter = index + 1

  percentage = ((counter * 100) / @attachments_total).round.to_s.rjust(3)

  filename = attachment['filename'] || 'nil.txt'
  filepath = "#{OUTPUT_DIR_JIRA_ATTACHMENTS}/#{filename}"
  nr = 0
  while File.exist?(filepath)
    nr += 1
    goodbye("Failed for filepath='#{filepath}', nr=#{nr}") if nr > 999
    extname = File.extname(filepath)
    basename = File.basename(filepath, extname)
    dirname = File.dirname(filepath)
    basename.sub!(/\.\d{3}$/, '')
    filename = "#{basename}.#{nr.to_s.rjust(3, '0')}#{extname}"
    filepath = "#{dirname}/#{filename}"
  end
  
  puts "Downloading: #{url}"
  puts "#{percentage}% [#{counter}|#{@attachments_total}] #{created_at} #{assembla_ticket_id} '#{filename}' (#{content_type})"
  begin
    content = RestClient::Request.execute(method: :get, url: url, headers: ASSEMBLA_HEADERS)
    IO.binwrite(filepath, content)
    @jira_attachments << {
      created_at: created_at,
      created_by: created_by,
      assembla_attachment_id: id,
      assembla_ticket_id: assembla_ticket_id,
      filename: filename,
      content_type: content_type
    }
  rescue RestClient::ExceptionWithResponse => e
    rest_client_exception(e, 'GET', url)
  end
end

puts "Total all: #{@attachments_total}"
attachments_jira_csv = "#{OUTPUT_DIR_JIRA}/jira-attachments-download.csv"
write_csv_file(attachments_jira_csv, @jira_attachments)
