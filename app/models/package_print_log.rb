# app/models/package_print_log.rb
class PackagePrintLog < ApplicationRecord
  belongs_to :package
  belongs_to :user

  # Print contexts
  enum print_context: {
    qr_scan: 'qr_scan',                    # Printed via QR scanning
    bulk_scan: 'bulk_scan',                # Printed via bulk scanning
    manual_print: 'manual_print',          # Manually printed from dashboard
    package_creation: 'package_creation',  # Auto-printed on package creation
    reprint: 'reprint',                    # Reprinted label
    warehouse_sort: 'warehouse_sort',      # Printed during warehouse sorting
    customer_request: 'customer_request'   # Printed upon customer request
  }

  # Print status
  enum status: {
    pending: 'pending',       # Print job queued
    printing: 'printing',     # Currently printing
    completed: 'completed',   # Successfully printed
    failed: 'failed',         # Print job failed
    cancelled: 'cancelled'    # Print job cancelled
  }

  # Validations
  validates :printed_at, presence: true
  validates :print_context, presence: true
  validates :status, presence: true
  validates :package, presence: true
  validates :user, presence: true
  validates :copies_printed, presence: true, numericality: { greater_than: 0 }

  # Scopes
  scope :recent, -> { order(printed_at: :desc) }
  scope :today, -> { where(printed_at: Date.current.all_day) }
  scope :this_week, -> { where(printed_at: 1.week.ago..Time.current) }
  scope :this_month, -> { where(printed_at: 1.month.ago..Time.current) }
  scope :by_user, ->(user) { where(user: user) }
  scope :by_package, ->(package) { where(package: package) }
  scope :by_context, ->(context) { where(print_context: context) }
  scope :by_status, ->(status) { where(status: status) }
  scope :successful, -> { where(status: 'completed') }
  scope :failed, -> { where(status: 'failed') }
  scope :scanning_prints, -> { where(print_context: ['qr_scan', 'bulk_scan']) }
  scope :manual_prints, -> { where(print_context: ['manual_print', 'reprint']) }

  # Callbacks
  before_validation :set_defaults
  after_create :create_tracking_event
  after_update :update_tracking_event, if: :saved_change_to_status?

  # Class methods
  def self.print_statistics(start_date: 1.month.ago, end_date: Time.current)
    logs = where(printed_at: start_date..end_date)
    
    {
      total_prints: logs.count,
      successful_prints: logs.successful.count,
      failed_prints: logs.failed.count,
      total_copies: logs.sum(:copies_printed),
      unique_packages: logs.select(:package_id).distinct.count,
      unique_users: logs.select(:user_id).distinct.count,
      prints_by_context: logs.group(:print_context).count,
      prints_by_status: logs.group(:status).count,
      prints_by_role: logs.joins(:user).group('users.role').count,
      prints_by_day: logs.group_by_day(:printed_at).count,
      average_prints_per_day: (logs.count / ((end_date - start_date) / 1.day).ceil.to_f).round(2),
      success_rate: logs.count > 0 ? (logs.successful.count / logs.count.to_f * 100).round(2) : 0
    }
  end

  def self.user_print_summary(user, period: 1.month)
    logs = by_user(user).where(printed_at: period.ago..Time.current)
    
    {
      total_prints: logs.count,
      successful_prints: logs.successful.count,
      failed_prints: logs.failed.count,
      total_copies: logs.sum(:copies_printed),
      packages_printed: logs.select(:package_id).distinct.count,
      contexts_used: logs.group(:print_context).count,
      recent_prints: logs.recent.limit(10).map(&:print_summary),
      performance: {
        success_rate: logs.count > 0 ? (logs.successful.count / logs.count.to_f * 100).round(2) : 0,
        average_per_day: (logs.count / 30.0).round(2),
        most_common_context: logs.group(:print_context).count.max_by(&:last)&.first
      }
    }
  end

  def self.package_print_history(package)
    by_package(package).recent.map do |log|
      {
        id: log.id,
        printed_at: log.printed_at,
        printed_by: log.user.name,
        context: log.print_context_display,
        status: log.status,
        copies: log.copies_printed,
        metadata: log.metadata
      }
    end
  end

  def self.create_print_log(package:, user:, context:, metadata: {})
    create!(
      package: package,
      user: user,
      print_context: context,
      printed_at: Time.current,
      status: 'completed',
      copies_printed: metadata[:copies] || 1,
      metadata: default_print_metadata.merge(metadata)
    )
  end

  def self.create_bulk_print_logs(packages:, user:, context:, metadata: {})
    logs = []
    timestamp = Time.current
    
    packages.each do |package|
      logs << new(
        package: package,
        user: user,
        print_context: context,
        printed_at: timestamp,
        status: 'completed',
        copies_printed: metadata[:copies] || 1,
        metadata: default_print_metadata.merge(metadata).merge(
          bulk_operation: true,
          package_code: package.code
        )
      )
    end
    
    import(logs, validate: true)
    logs
  end

  def self.default_print_metadata
    {
      print_method: 'mobile_app',
      timestamp: Time.current.iso8601,
      app_version: Rails.application.class.module_parent_name
    }
  end

  # Instance methods
  def print_context_display
    case print_context
    when 'qr_scan'
      'QR Scan Print'
    when 'bulk_scan'
      'Bulk Scan Print'
    when 'manual_print'
      'Manual Print'
    when 'package_creation'
      'Auto Print on Creation'
    when 'reprint'
      'Reprint'
    when 'warehouse_sort'
      'Warehouse Sort Print'
    when 'customer_request'
      'Customer Request Print'
    else
      print_context.humanize
    end
  end

  def status_display
    case status
    when 'pending'
      'Queued for Printing'
    when 'printing'
      'Currently Printing'
    when 'completed'
      'Successfully Printed'
    when 'failed'
      'Print Failed'
    when 'cancelled'
      'Print Cancelled'
    else
      status.humanize
    end
  end

  def print_summary
    {
      id: id,
      package_code: package.code,
      printed_at: printed_at,
      context: print_context_display,
      status: status_display,
      copies: copies_printed,
      success: completed?
    }
  end

  def bulk_operation?
    metadata['bulk_operation'] == true
  end

  def scanning_print?
    ['qr_scan', 'bulk_scan'].include?(print_context)
  end

  def manual_print?
    ['manual_print', 'reprint', 'customer_request'].include?(print_context)
  end

  def auto_print?
    print_context == 'package_creation'
  end

  def warehouse_print?
    print_context == 'warehouse_sort'
  end

  def printer_info
    printer_data = metadata['printer_info']
    return nil unless printer_data.is_a?(Hash)

    {
      printer_name: printer_data['printer_name'],
      printer_id: printer_data['printer_id'],
      print_quality: printer_data['print_quality'],
      paper_size: printer_data['paper_size']
    }
  end

  def location_info
    location_data = metadata['location']
    return nil unless location_data

    if location_data.is_a?(Hash)
      {
        latitude: location_data['latitude'],
        longitude: location_data['longitude'],
        address: location_data['address']
      }
    else
      { address: location_data.to_s }
    end
  end

  def print_station
    metadata['print_station'] || metadata['location'] || 'Unknown Station'
  end

  def processing_time
    return nil unless metadata['processing_time']
    
    metadata['processing_time'].to_f
  end

  def error_message
    return nil unless failed?
    
    metadata['error_message'] || metadata['failure_reason'] || 'Unknown error'
  end

  def retry_count
    metadata['retry_count'] || 0
  end

  def can_retry?
    failed? && retry_count < 3
  end

  def time_since_print
    Time.current - printed_at
  end

  def formatted_print_time
    printed_at.strftime('%Y-%m-%d %H:%M:%S %Z')
  end

  def reprint!(new_user: nil, context: 'reprint', metadata: {})
    new_log = self.class.create!(
      package: package,
      user: new_user || user,
      print_context: context,
      printed_at: Time.current,
      status: 'completed',
      copies_printed: 1,
      metadata: self.class.default_print_metadata.merge(metadata).merge(
        original_print_log_id: id,
        reprint_reason: metadata[:reason] || 'Manual reprint'
      )
    )
    
    new_log
  end

  def mark_as_failed!(error_message: nil)
    update!(
      status: 'failed',
      metadata: metadata.merge(
        failure_time: Time.current.iso8601,
        error_message: error_message,
        retry_count: retry_count + 1
      )
    )
  end

  def mark_as_completed!(processing_time: nil)
    update!(
      status: 'completed',
      metadata: metadata.merge(
        completion_time: Time.current.iso8601,
        processing_time: processing_time
      )
    )
  end

  # JSON serialization
  def as_json(options = {})
    result = super(options.except(:include_package, :include_user, :include_printer))
    
    result.merge!(
      'print_context_display' => print_context_display,
      'status_display' => status_display,
      'bulk_operation' => bulk_operation?,
      'scanning_print' => scanning_print?,
      'manual_print' => manual_print?,
      'print_station' => print_station,
      'time_since_print' => time_since_print,
      'formatted_print_time' => formatted_print_time,
      'can_retry' => can_retry?
    )

    # Include package info if requested
    if options[:include_package]
      result['package'] = {
        id: package.id,
        code: package.code,
        state: package.state,
        route_description: package.route_description
      }
    end

    # Include user info if requested
    if options[:include_user]
      result['user'] = {
        id: user.id,
        name: user.name,
        role: user.role,
        role_display: user.role_display_name
      }
    end

    # Include printer info if requested and available
    if options[:include_printer] && printer_info
      result['printer'] = printer_info
    end

    # Include error details for failed prints
    if failed? && error_message
      result['error_details'] = {
        error_message: error_message,
        retry_count: retry_count,
        can_retry: can_retry?
      }
    end

    result
  end

  private

  def set_defaults
    self.printed_at ||= Time.current
    self.status ||= 'completed'
    self.copies_printed ||= 1
    self.metadata ||= {}
    self.metadata = self.class.default_print_metadata.merge(metadata)
  end

  def create_tracking_event
    return unless defined?(PackageTrackingEvent)
    
    event_type = case user.role
    when 'agent'
      'printed_by_agent'
    when 'warehouse'
      'printed_by_warehouse'
    else
      'printed_by_agent' # fallback
    end
    
    PackageTrackingEvent.create!(
      package: package,
      user: user,
      event_type: event_type,
      metadata: {
        print_log_id: id,
        print_context: print_context,
        copies_printed: copies_printed,
        print_station: print_station,
        bulk_operation: bulk_operation?
      }.merge(metadata.slice('location', 'device_info'))
    )
  rescue => e
    Rails.logger.error "Failed to create tracking event for print log #{id}: #{e.message}"
  end

  def update_tracking_event
    return unless defined?(PackageTrackingEvent)
    
    # Find the related tracking event and update its metadata
    tracking_event = PackageTrackingEvent.where(
      package: package,
      user: user,
      event_type: ['printed_by_agent', 'printed_by_warehouse']
    ).where("metadata->>'print_log_id' = ?", id.to_s).first
    
    if tracking_event
      tracking_event.metadata['print_status'] = status
      tracking_event.metadata['status_updated_at'] = Time.current.iso8601
      tracking_event.metadata['error_message'] = error_message if failed?
      tracking_event.save!
    end
  rescue => e
    Rails.logger.error "Failed to update tracking event for print log #{id}: #{e.message}"
  end
end