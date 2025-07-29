module Api
  module V1
    class InvitesController < ApplicationController
      before_action :authenticate_user!

      def create
        business = current_user.businesses.find_by(id: params[:business_id])

        unless business
          return render json: { error: 'Business not found or unauthorized' }, status: :not_found
        end

        invite = business.business_invites.new(
          inviter: current_user,
          expires_at: 3.days.from_now
        )

        if invite.save
          render json: { code: invite.code }, status: :created
        else
          render json: { errors: invite.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def accept
        invite = BusinessInvite.find_by(code: params[:code])

        if invite && invite.expires_at > Time.current
          if UserBusiness.exists?(user: current_user, business: invite.business)
            return render json: { message: "You're already part of this business." }, status: :ok
          end

          UserBusiness.create!(user: current_user, business: invite.business, role: 'staff')
          invite.destroy
          render json: { message: "Joined business successfully." }, status: :ok
        else
          render json: { error: "Invite is invalid or expired." }, status: :unprocessable_entity
        end
      end
    end
  end
end