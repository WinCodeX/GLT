# app/models/business_activity.rb
class BusinessActivity < ApplicationRecord
  belongs_to :business
  belongs_to :user
  belongs_to :target_user, class_name: 'User', optional: true
  belongs_to :package, optional: true

  # Activity types for business events
  enum activity_type: {
    # Package activities
    package_created: 'package_created',
    package_delivered: 'package_delivered',
    package_cancelled: 'package_cancelled',
    
    # Staff activities
    staff_joined: 'staff_joined',
    staff_removed: 'staff_removed',
    invite_sent: 'invite_sent',
    invite_accepted: 'invite_accepted',
    
    # Business management
    business_updated: 'business_updated',
    logo_updated: 'logo_updated',
    categories_updated: 'categories_updated',
    
    # System activities
    business_created: 'business_created'
  }

  # Validations
  validates :activity_type, presence: true
  validates :business, presence: true
  validates :user, presence: true
  validates :description, presence: true
  validates :metadata, presence: true

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :today, -> { where(created_at: Date.current.all_day) }
  scope :this_week, -> { where(created_at: 1.week.ago..Time.current) }
  scope :this_month, -> { where(created_at: 1.month.ago..Time.current) }
  scope :by_user, ->(user) { where(user: user) }
  scope :by_activity_type, ->(type) { where(activity_type: type) }
  scope :package_activities, -> { where(activity_type: ['package_created', 'package_delivered', 'package_cancelled']) }
  scope :staff_activities, -> { where(activity_type: ['staff_joined', 'staff_removed', 'invite_sent', 'invite_accepted']) }

  # Callbacks
  before_validation :set_default_metadata
  # Removed problematic before_create callback

  # ENHANCED: Class methods - Generate detailed activity descriptions with package and recipient info
  def self.create_package_activity(business:, user:, package:, activity_type:, metadata: {})
    # ENHANCED: Enrich metadata with package and recipient details
    enriched_metadata = default_metadata.merge(metadata).merge({
      package_code: package&.code,
      package_id: package&.id,
      recipient_name: package&.receiver_name,
      recipient_phone: package&.receiver_phone,
      sender_name: package&.sender_name,
      delivery_location: package&.delivery_location,
      delivery_type: package&.delivery_type,
      cost: package&.cost
    })
    
    activity = new(
      business: business,
      user: user,
      package: package,
      activity_type: activity_type,
      metadata: enriched_metadata,
      target_user: nil # Simplified - no target_user for package activities
    )
    
    # Generate detailed description explicitly BEFORE validation
    activity.description = activity.generate_detailed_description_for_activity
    
    activity.save!
    activity
  rescue => e
    Rails.logger.error "Failed to create package activity: #{e.message}"
    raise e
  end

  def self.create_staff_activity(business:, user:, target_user:, activity_type:, metadata: {})
    activity = new(
      business: business,
      user: user,
      target_user: target_user,
      activity_type: activity_type,
      metadata: default_metadata.merge(metadata)
    )
    
    activity.description = activity.generate_detailed_description_for_activity
    activity.save!
    activity
  end

  def self.create_business_activity(business:, user:, activity_type:, metadata: {})
    activity = new(
      business: business,
      user: user,
      activity_type: activity_type,
      metadata: default_metadata.merge(metadata)
    )
    
    activity.description = activity.generate_detailed_description_for_activity
    activity.save!
    activity
  end

  def self.activities_summary(business:, start_date: 1.month.ago, end_date: Time.current)
    activities = where(business: business, created_at: start_date..end_date)
    
    # Use standard SQL grouping instead of groupdate gem
    activities_by_day = activities
      .group("DATE(created_at)")
      .count
      .transform_keys { |date_str| Date.parse(date_str).strftime('%Y-%m-%d') }
    
    {
      total_activities: activities.count,
      package_activities: activities.package_activities.count,
      staff_activities: activities.staff_activities.count,
      activities_by_type: activities.group(:activity_type).count,
      activities_by_day: activities_by_day,
      recent_activities: activities.recent.limit(10).map(&:summary_json)
    }
  end

  # Instance methods
  def activity_icon
    case activity_type
    when 'package_created'
      'package'
    when 'package_delivered'
      'check-circle'
    when 'package_cancelled'
      'x-circle'
    when 'staff_joined', 'invite_accepted'
      'user-plus'
    when 'staff_removed'
      'user-minus'
    when 'invite_sent'
      'mail'
    when 'business_updated', 'logo_updated', 'categories_updated'
      'edit'
    when 'business_created'
      'briefcase'
    else
      'activity'
    end
  end

  def activity_color
    case activity_type
    when 'package_created', 'staff_joined', 'invite_accepted', 'business_created'
      '#10b981' # Green
    when 'package_delivered'
      '#3b82f6' # Blue
    when 'package_cancelled', 'staff_removed'
      '#ef4444' # Red
    when 'invite_sent', 'business_updated', 'logo_updated', 'categories_updated'
      '#f59e0b' # Orange
    else
      '#6b7280' # Gray
    end
  end

  def formatted_time
    if created_at.today?
      created_at.strftime('%I:%M %p')
    elsif created_at > 1.week.ago
      created_at.strftime('%a %I:%M %p')
    else
      created_at.strftime('%b %d, %Y')
    end
  end

  def summary_json
    # Use full_name instead of name to avoid NoMethodError
    user_name = safe_user_name
    target_user_name = safe_target_user_name
    
    {
      id: id,
      activity_type: activity_type,
      description: description,
      formatted_time: formatted_time,
      activity_icon: activity_icon,
      activity_color: activity_color,
      user: {
        id: user.id,
        name: user_name,
        avatar_url: user.respond_to?(:avatar_url) ? user.avatar_url : nil
      },
      target_user: target_user ? {
        id: target_user.id,
        name: target_user_name
      } : nil,
      package: package ? {
        id: package.id,
        code: package.code
      } : nil,
      metadata: metadata
    }
  end

  # ENHANCED: Generate detailed description with package codes and recipient information
  def generate_detailed_description_for_activity
    user_name = safe_user_name
    target_user_name = safe_target_user_name
    
    case activity_type
    when 'package_created'
      # ENHANCED: Include package code and recipient name for detailed descriptions
      package_code = package&.code || metadata&.dig('package_code') || 'unknown'
      recipient_name = metadata&.dig('recipient_name') || 'recipient'
      
      base_description = if target_user
        "#{user_name} created a package for #{target_user_name}"
      else
        "#{user_name} created a package"
      end
      
      # Add package code
      detailed_description = "#{user_name} created a package (#{package_code})"
      
      # Add recipient name if available and not generic
      if recipient_name.present? && recipient_name != 'recipient'
        detailed_description += " for #{recipient_name}"
      end
      
      detailed_description
      
    when 'package_delivered'
      package_code = package&.code || metadata&.dig('package_code') || 'unknown'
      "Package (#{package_code}) was delivered"
      
    when 'package_cancelled'
      package_code = package&.code || metadata&.dig('package_code') || 'unknown'
      "Package (#{package_code}) was cancelled"
      
    when 'staff_joined'
      "#{target_user_name} joined the business"
      
    when 'staff_removed'
      "#{target_user_name} was removed from the business"
      
    when 'invite_sent'
      "#{user_name} sent an invite to join the business"
      
    when 'invite_accepted'
      "#{target_user_name} accepted the invitation"
      
    when 'business_updated'
      "#{user_name} updated business information"
      
    when 'logo_updated'
      "#{user_name} updated the business logo"
      
    when 'categories_updated'
      "#{user_name} updated business categories"
      
    when 'business_created'
      "#{user_name} created the business"
      
    else
      "#{user_name} performed #{activity_type&.humanize&.downcase || 'an action'}"
    end
  rescue => e
    Rails.logger.error "Failed to generate detailed description: #{e.message}"
    "Activity performed" # Fallback description
  end

  # NOTE: This method generates the base description stored in the database.
  # For personalized display (showing "You" instead of username), 
  # the BusinessesController handles that transformation at display time.
  def generate_description_for_activity
    # Delegate to the detailed description method for consistency
    generate_detailed_description_for_activity
  end

  # ENHANCED: Method to generate personalized description based on viewer
  # This is used by the BusinessesController for display customization
  def personalized_description_for_viewer(viewer_user)
    begin
      # Determine if the activity user is the viewer ("you") or someone else
      actor_name = if user == viewer_user
        "You"
      else
        safe_user_name
      end
      
      target_name = target_user ? safe_target_user_name : nil
      
      case activity_type
      when 'package_created'
        # ENHANCED: Include package code and recipient name for personalized descriptions
        package_code = package&.code || metadata&.dig('package_code') || 'unknown'
        recipient_name = metadata&.dig('recipient_name') || nil
        
        base_description = "#{actor_name} created a package (#{package_code})"
        
        # Add recipient name if available
        if recipient_name.present? && recipient_name.strip.downcase != 'recipient'
          base_description += " for #{recipient_name}"
        end
        
        base_description
        
      when 'package_delivered'
        package_code = package&.code || metadata&.dig('package_code') || 'unknown'
        "Package (#{package_code}) was delivered"
        
      when 'package_cancelled'
        package_code = package&.code || metadata&.dig('package_code') || 'unknown'
        "Package (#{package_code}) was cancelled"
        
      when 'staff_joined'
        if target_name
          "#{target_name} joined the business"
        else
          "#{actor_name} joined the business"
        end
        
      when 'staff_removed'
        if target_name
          "#{target_name} was removed from the business"
        else
          "Staff member was removed"
        end
        
      when 'invite_sent'
        "#{actor_name} sent an invite to join the business"
        
      when 'invite_accepted'
        if target_name
          "#{target_name} accepted the invitation"
        else
          "#{actor_name} accepted the invitation"
        end
        
      when 'business_updated'
        "#{actor_name} updated business information"
        
      when 'logo_updated'
        "#{actor_name} updated the business logo"
        
      when 'categories_updated'
        "#{actor_name} updated business categories"
        
      when 'business_created'
        "#{actor_name} created the business"
        
      else
        "#{actor_name} performed #{activity_type&.humanize&.downcase || 'an action'}"
      end
      
    rescue => e
      Rails.logger.error "Failed to generate personalized description: #{e.message}"
      description || "Activity performed" # Fallback to stored description or generic
    end
  end

  private

  def self.default_metadata
    {
      timestamp: Time.current.iso8601,
      app_version: Rails.application.class.module_parent_name
    }
  end

  def set_default_metadata
    self.metadata ||= {}
    self.metadata = self.class.default_metadata.merge(metadata)
  end

  # FIXED: Safe user name extraction with multiple fallbacks
  def safe_user_name
    return 'Unknown User' unless user
    
    if user.respond_to?(:full_name) && user.full_name.present?
      user.full_name
    elsif user.respond_to?(:name) && user.name.present?
      user.name
    elsif user.email.present?
      user.email
    else
      "User ##{user.id}"
    end
  rescue => e
    Rails.logger.error "Failed to get user name: #{e.message}"
    'Unknown User'
  end

  # FIXED: Safe target user name extraction
  def safe_target_user_name
    return 'Unknown User' unless target_user
    
    if target_user.respond_to?(:full_name) && target_user.full_name.present?
      target_user.full_name
    elsif target_user.respond_to?(:name) && target_user.name.present?
      target_user.name
    elsif target_user.email.present?
      target_user.email
    else
      "User ##{target_user.id}"
    end
  rescue => e
    Rails.logger.error "Failed to get target user name: #{e.message}"
    'Unknown User'
  end
end