# app/controllers/api/v1/contacts_controller.rb
module Api
  module V1
    class ContactsController < ApplicationController
      before_action :authenticate_user!
      
      # Force JSON responses for all actions
      respond_to :json

      # POST /api/v1/contacts/check_registered
      def check_registered
        begin
          phone_numbers = params[:phone_numbers]
          
          # Validate input
          unless phone_numbers.is_a?(Array) && phone_numbers.present?
            render json: {
              success: false,
              message: 'Phone numbers array is required'
            }, status: :bad_request
            return
          end

          # Limit the number of phone numbers to prevent abuse
          if phone_numbers.length > 1000
            render json: {
              success: false,
              message: 'Maximum 1000 phone numbers allowed per request'
            }, status: :bad_request
            return
          end

          Rails.logger.info "Checking #{phone_numbers.length} phone numbers for registration status"

          # Clean and normalize phone numbers
          normalized_numbers = phone_numbers.map do |number|
            normalize_phone_number(number.to_s)
          end.compact.uniq

          Rails.logger.info "Normalized to #{normalized_numbers.length} unique phone numbers"

          # Find registered users by phone numbers
          # Check both normalized and original formats to handle different phone number formats
          registered_users = User.where(
            "REGEXP_REPLACE(phone_number, '[^0-9]', '', 'g') IN (?) OR phone_number IN (?)",
            normalized_numbers,
            phone_numbers
          ).pluck(:phone_number)

          # Normalize the found phone numbers for consistent comparison
          registered_normalized = registered_users.map { |phone| normalize_phone_number(phone) }.compact

          Rails.logger.info "Found #{registered_normalized.length} registered phone numbers"

          render json: {
            success: true,
            registered_numbers: registered_normalized,
            total_checked: normalized_numbers.length,
            registered_count: registered_normalized.length
          }, status: :ok

        rescue => e
          Rails.logger.error "ContactsController#check_registered error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render json: {
            success: false,
            message: 'Failed to check registered contacts',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/contacts/my_contacts (optional - for syncing contact list to server)
      def my_contacts
        begin
          # Get current user's contacts if they've synced them
          # This could be useful for features like "People you may know"
          
          render json: {
            success: true,
            message: 'Contact sync feature coming soon'
          }, status: :ok

        rescue => e
          Rails.logger.error "ContactsController#my_contacts error: #{e.message}"
          
          render json: {
            success: false,
            message: 'Failed to fetch contacts',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/contacts/sync (optional - for syncing user's contacts to server)
      def sync
        begin
          # This endpoint could be used to sync user's contacts to the server
          # for features like "Find friends" or contact recommendations
          
          render json: {
            success: true,
            message: 'Contact sync feature coming soon'
          }, status: :ok

        rescue => e
          Rails.logger.error "ContactsController#sync error: #{e.message}"
          
          render json: {
            success: false,
            message: 'Failed to sync contacts',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      private

      # Normalize phone number to digits only for consistent comparison
      def normalize_phone_number(phone_number)
        return nil if phone_number.blank?
        
        # Remove all non-digit characters
        normalized = phone_number.gsub(/\D/, '')
        
        # Handle different international formats
        case normalized.length
        when 10
          # US number without country code - add +1
          "+1#{normalized}"
        when 11
          # US number with country code 1
          "+#{normalized}" if normalized.start_with?('1')
        when 12
          # International number with country code
          "+#{normalized}"
        when 13
          # Number that already has + prefix removed
          "+#{normalized}"
        else
          # For other lengths, just add + if it's a reasonable phone number length
          normalized.length >= 8 && normalized.length <= 15 ? "+#{normalized}" : nil
        end
      end

      # Alternative normalization method that's more flexible
      def normalize_phone_number_flexible(phone_number)
        return nil if phone_number.blank?
        
        # Remove all non-digit characters
        digits_only = phone_number.gsub(/\D/, '')
        
        # Return digits only for comparison - let the frontend handle formatting
        digits_only.length >= 8 ? digits_only : nil
      end
    end
  end
end