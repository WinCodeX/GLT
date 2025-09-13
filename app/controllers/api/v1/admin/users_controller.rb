# app/controllers/api/v1/admin/users_controller.rb
module Api
  module V1
    module Admin
      class UsersController < ApplicationController
        before_action :authenticate_user!
        before_action :ensure_admin_user!
        
        respond_to :json

        # GET /api/v1/admin/users/search
        def search
          begin
            query = params[:q]&.strip || params[:query]&.strip
            
            if query.blank?
              return render json: {
                success: false,
                message: 'Search query is required',
                data: []
              }, status: :bad_request
            end

            # Search users by email, phone number, name, and associated package codes
            users = search_users(query)
            
            # Pagination
            page = [params[:page].to_i, 1].max
            per_page = [params[:per_page].to_i, 20].max.clamp(1, 100)
            total_count = users.count
            users = users.offset((page - 1) * per_page).limit(per_page)
            
            render json: {
              success: true,
              data: users.map { |user| serialize_user_for_admin_search(user) },
              query: query,
              pagination: {
                current_page: page,
                per_page: per_page,
                total_count: total_count,
                total_pages: (total_count.to_f / per_page).ceil
              }
            }, status: :ok
            
          rescue => e
            Rails.logger.error "Admin::UsersController#search error: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
            
            render json: {
              success: false,
              message: 'Search failed',
              error: Rails.env.development? ? e.message : nil
            }, status: :internal_server_error
          end
        end

        private

        def search_users(query)
          # Build search query for multiple fields
          search_query = "%#{query}%"
          
          # Search in user fields
          users = User.includes(:packages, :roles)
                      .where(
                        "email ILIKE ? OR phone_number ILIKE ? OR first_name ILIKE ? OR last_name ILIKE ? OR CONCAT(first_name, ' ', last_name) ILIKE ?",
                        search_query, search_query, search_query, search_query, search_query
                      )

          # Also search users who have packages with matching codes
          users_with_package_codes = User.includes(:packages, :roles)
                                        .joins(:packages)
                                        .where("packages.code ILIKE ?", search_query)

          # Combine both searches and remove duplicates
          User.where(id: users.pluck(:id) + users_with_package_codes.pluck(:id))
              .includes(:packages, :roles)
              .distinct
              .order(:email)
        end

        def serialize_user_for_admin_search(user)
          {
            id: user.id,
            email: user.email,
            phone_number: user.phone_number,
            first_name: user.first_name,
            last_name: user.last_name,
            full_name: "#{user.first_name} #{user.last_name}".strip,
            display_name: user.display_name,
            roles: user.roles.pluck(:name),
            primary_role: user.primary_role,
            role_display: user.role_display_name,
            packages_count: user.packages.count,
            package_codes: user.packages.limit(5).pluck(:code), # Show first 5 package codes
            avatar_url: user.avatar.attached? ? url_for(user.avatar) : nil,
            created_at: user.created_at,
            last_seen_at: user.last_seen_at,
            is_active: user.active?
          }
        end

        def ensure_admin_user!
          unless current_user.admin?
            render json: {
              success: false,
              message: 'Access denied. Admin privileges required.',
              error: 'insufficient_permissions'
            }, status: :forbidden
          end
        end
      end
    end
  end
end