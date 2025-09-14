# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2025_09_14_114040) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "agents", force: :cascade do |t|
    t.string "name"
    t.string "phone"
    t.bigint "area_id", null: false
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "active"
    t.index ["area_id"], name: "index_agents_on_area_id"
    t.index ["user_id"], name: "index_agents_on_user_id"
  end

  create_table "app_updates", force: :cascade do |t|
    t.string "version", null: false
    t.string "update_id", null: false
    t.string "runtime_version", default: "1.0.0"
    t.text "changelog", default: [], array: true
    t.boolean "published", default: false
    t.boolean "force_update", default: false
    t.datetime "published_at"
    t.json "assets", default: []
    t.text "description"
    t.integer "download_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "apk_url"
    t.string "apk_key"
    t.bigint "apk_size"
    t.string "apk_filename"
    t.index ["apk_key"], name: "index_app_updates_on_apk_key"
    t.index ["published", "created_at"], name: "index_app_updates_on_published_and_created_at"
    t.index ["update_id"], name: "index_app_updates_on_update_id", unique: true
    t.index ["version"], name: "index_app_updates_on_version"
  end

  create_table "areas", force: :cascade do |t|
    t.string "name"
    t.bigint "location_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "initials", limit: 3
    t.index ["initials"], name: "idx_areas_initials", unique: true
    t.index ["location_id"], name: "index_areas_on_location_id"
  end

  create_table "business_categories", force: :cascade do |t|
    t.bigint "business_id", null: false
    t.bigint "category_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id", "category_id"], name: "index_business_categories_on_business_and_category", unique: true
    t.index ["business_id"], name: "index_business_categories_on_business_id"
    t.index ["category_id"], name: "index_business_categories_on_category_id"
  end

  create_table "business_invites", force: :cascade do |t|
    t.string "code", null: false
    t.bigint "inviter_id", null: false
    t.bigint "business_id", null: false
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id"], name: "index_business_invites_on_business_id"
    t.index ["code"], name: "index_business_invites_on_code", unique: true
    t.index ["inviter_id"], name: "index_business_invites_on_inviter_id"
  end

  create_table "businesses", force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.bigint "owner_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "phone_number"
    t.string "logo_url"
    t.index ["logo_url"], name: "index_businesses_on_logo_url"
    t.index ["owner_id"], name: "index_businesses_on_owner_id"
    t.index ["phone_number"], name: "index_businesses_on_phone_number"
  end

  create_table "categories", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.text "description"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_categories_on_active"
    t.index ["name"], name: "index_categories_on_name"
    t.index ["slug"], name: "index_categories_on_slug", unique: true
  end

  create_table "conversation_participants", force: :cascade do |t|
    t.bigint "conversation_id", null: false
    t.bigint "user_id", null: false
    t.string "role", default: "participant"
    t.datetime "joined_at"
    t.datetime "last_read_at"
    t.boolean "notifications_enabled", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "user_id"], name: "index_conv_participants_on_conv_and_user", unique: true
    t.index ["conversation_id"], name: "index_conversation_participants_on_conversation_id"
    t.index ["role"], name: "index_conversation_participants_on_role"
    t.index ["user_id"], name: "index_conversation_participants_on_user_id"
  end

  create_table "conversations", force: :cascade do |t|
    t.string "conversation_type", null: false
    t.string "title"
    t.json "metadata", default: {}
    t.datetime "last_activity_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "((metadata ->> 'status'::text))", name: "index_conversations_on_status"
    t.index "((metadata ->> 'ticket_id'::text))", name: "index_conversations_on_ticket_id"
    t.index ["conversation_type"], name: "index_conversations_on_conversation_type"
    t.index ["last_activity_at"], name: "index_conversations_on_last_activity_at"
  end

  create_table "locations", force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "initials", limit: 3
    t.index ["initials"], name: "index_locations_on_initials", unique: true
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "conversation_id", null: false
    t.bigint "user_id", null: false
    t.text "content"
    t.integer "message_type", default: 0
    t.json "metadata", default: {}
    t.boolean "is_system", default: false
    t.datetime "edited_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["created_at"], name: "index_messages_on_created_at"
    t.index ["is_system"], name: "index_messages_on_is_system"
    t.index ["message_type"], name: "index_messages_on_message_type"
    t.index ["user_id"], name: "index_messages_on_user_id"
  end

  create_table "mpesa_transactions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "package_id", null: false
    t.string "checkout_request_id", null: false
    t.string "merchant_request_id", null: false
    t.string "phone_number", null: false
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.string "status", default: "pending", null: false
    t.integer "result_code"
    t.text "result_desc"
    t.string "mpesa_receipt_number"
    t.string "callback_phone_number"
    t.decimal "callback_amount", precision: 10, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["checkout_request_id"], name: "index_mpesa_transactions_on_checkout_request_id", unique: true
    t.index ["merchant_request_id"], name: "index_mpesa_transactions_on_merchant_request_id"
    t.index ["mpesa_receipt_number"], name: "index_mpesa_transactions_on_mpesa_receipt_number"
    t.index ["package_id", "status"], name: "index_mpesa_transactions_on_package_id_and_status"
    t.index ["package_id"], name: "index_mpesa_transactions_on_package_id"
    t.index ["status"], name: "index_mpesa_transactions_on_status"
    t.index ["user_id", "status"], name: "index_mpesa_transactions_on_user_id_and_status"
    t.index ["user_id"], name: "index_mpesa_transactions_on_user_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "package_id"
    t.string "title", null: false
    t.text "message", null: false
    t.string "notification_type", null: false
    t.json "metadata", default: {}
    t.boolean "read", default: false
    t.boolean "delivered", default: false
    t.datetime "read_at"
    t.datetime "delivered_at"
    t.string "channel", default: "in_app"
    t.integer "priority", default: 0
    t.datetime "expires_at"
    t.string "action_url"
    t.string "icon"
    t.string "status", default: "pending"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_notifications_on_created_at"
    t.index ["delivered", "status"], name: "index_notifications_on_delivered_and_status"
    t.index ["expires_at", "status"], name: "index_notifications_on_expires_at_and_status"
    t.index ["package_id"], name: "index_notifications_on_package_id"
    t.index ["user_id", "notification_type"], name: "index_notifications_on_user_id_and_notification_type"
    t.index ["user_id", "read"], name: "index_notifications_on_user_id_and_read"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "package_print_logs", force: :cascade do |t|
    t.bigint "package_id", null: false
    t.bigint "user_id", null: false
    t.datetime "printed_at", null: false
    t.string "print_context", default: "manual_print", null: false
    t.string "status", default: "completed", null: false
    t.integer "copies_printed", default: 1, null: false
    t.json "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["package_id", "printed_at"], name: "index_package_print_logs_on_package_id_and_printed_at"
    t.index ["package_id"], name: "index_package_print_logs_on_package_id"
    t.index ["print_context", "printed_at"], name: "index_package_print_logs_on_print_context_and_printed_at"
    t.index ["printed_at"], name: "index_package_print_logs_on_printed_at"
    t.index ["status", "printed_at"], name: "index_package_print_logs_on_status_and_printed_at"
    t.index ["user_id", "printed_at"], name: "index_package_print_logs_on_user_id_and_printed_at"
    t.index ["user_id"], name: "index_package_print_logs_on_user_id"
  end

  create_table "package_tracking_events", force: :cascade do |t|
    t.bigint "package_id", null: false
    t.bigint "user_id", null: false
    t.string "event_type", null: false
    t.json "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_package_tracking_events_on_created_at"
    t.index ["event_type", "created_at"], name: "index_package_tracking_events_on_event_type_and_created_at"
    t.index ["package_id", "created_at"], name: "index_package_tracking_events_on_package_id_and_created_at"
    t.index ["package_id", "event_type"], name: "index_package_tracking_events_on_package_id_and_event_type"
    t.index ["package_id"], name: "index_package_tracking_events_on_package_id"
    t.index ["user_id", "created_at"], name: "index_package_tracking_events_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_package_tracking_events_on_user_id"
  end

  create_table "packages", force: :cascade do |t|
    t.string "sender_name"
    t.string "sender_phone"
    t.string "receiver_name"
    t.string "receiver_phone"
    t.bigint "origin_area_id"
    t.bigint "destination_area_id"
    t.bigint "origin_agent_id"
    t.bigint "destination_agent_id"
    t.bigint "user_id", null: false
    t.string "delivery_type"
    t.string "state"
    t.integer "cost"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "code", null: false
    t.integer "route_sequence"
    t.text "delivery_location"
    t.string "shop_name"
    t.string "shop_contact"
    t.text "collection_address"
    t.text "items_to_collect"
    t.decimal "item_value", precision: 10, scale: 2
    t.text "item_description"
    t.string "payment_method", default: "mpesa"
    t.string "payment_status", default: "pending"
    t.string "payment_reference"
    t.text "special_instructions"
    t.string "priority_level", default: "normal"
    t.boolean "special_handling", default: false
    t.boolean "requires_payment_advance", default: false
    t.string "collection_type"
    t.decimal "pickup_latitude", precision: 10, scale: 6
    t.decimal "pickup_longitude", precision: 10, scale: 6
    t.decimal "delivery_latitude", precision: 10, scale: 6
    t.decimal "delivery_longitude", precision: 10, scale: 6
    t.datetime "payment_deadline"
    t.datetime "collection_scheduled_at"
    t.datetime "collected_at"
    t.text "pickup_location"
    t.text "package_description"
    t.string "package_size"
    t.integer "resubmission_count", default: 0
    t.string "original_state"
    t.text "rejection_reason"
    t.datetime "rejected_at"
    t.boolean "auto_rejected", default: false
    t.datetime "resubmitted_at"
    t.datetime "expiry_deadline"
    t.datetime "final_deadline"
    t.index ["auto_rejected"], name: "index_packages_on_auto_rejected"
    t.index ["code"], name: "idx_packages_code", unique: true
    t.index ["collection_scheduled_at"], name: "index_packages_on_collection_scheduled_at"
    t.index ["collection_type"], name: "index_packages_on_collection_type"
    t.index ["delivery_type", "state"], name: "index_packages_on_delivery_type_and_state"
    t.index ["destination_agent_id"], name: "index_packages_on_destination_agent_id"
    t.index ["destination_area_id"], name: "index_packages_on_destination_area_id"
    t.index ["expiry_deadline"], name: "index_packages_on_expiry_deadline"
    t.index ["final_deadline"], name: "index_packages_on_final_deadline"
    t.index ["origin_agent_id"], name: "index_packages_on_origin_agent_id"
    t.index ["origin_area_id", "destination_area_id", "route_sequence"], name: "idx_packages_route_seq"
    t.index ["origin_area_id"], name: "index_packages_on_origin_area_id"
    t.index ["payment_status", "state"], name: "index_packages_on_payment_status_and_state"
    t.index ["payment_status"], name: "index_packages_on_payment_status"
    t.index ["priority_level"], name: "index_packages_on_priority_level"
    t.index ["rejected_at"], name: "index_packages_on_rejected_at"
    t.index ["resubmission_count"], name: "index_packages_on_resubmission_count"
    t.index ["state", "expiry_deadline"], name: "index_packages_on_state_and_expiry_deadline"
    t.index ["state", "final_deadline"], name: "index_packages_on_state_and_final_deadline"
    t.index ["user_id"], name: "index_packages_on_user_id"
  end

  create_table "prices", force: :cascade do |t|
    t.bigint "origin_area_id"
    t.bigint "destination_area_id"
    t.integer "cost"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "origin_agent_id"
    t.bigint "destination_agent_id"
    t.string "delivery_type"
    t.string "package_size"
    t.index ["destination_agent_id"], name: "index_prices_on_destination_agent_id"
    t.index ["destination_area_id"], name: "index_prices_on_destination_area_id"
    t.index ["origin_agent_id"], name: "index_prices_on_origin_agent_id"
    t.index ["origin_area_id"], name: "index_prices_on_origin_area_id"
  end

  create_table "push_tokens", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "token", null: false
    t.string "platform", null: false
    t.json "device_info", default: {}
    t.boolean "active", default: true
    t.integer "failure_count", default: 0
    t.datetime "last_used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_push_tokens_on_active"
    t.index ["last_used_at"], name: "index_push_tokens_on_last_used_at"
    t.index ["token"], name: "index_push_tokens_on_token", unique: true
    t.index ["user_id", "platform"], name: "index_push_tokens_on_user_id_and_platform"
    t.index ["user_id"], name: "index_push_tokens_on_user_id"
  end

  create_table "roles", force: :cascade do |t|
    t.string "name"
    t.string "resource_type"
    t.bigint "resource_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name", "resource_type", "resource_id"], name: "index_roles_on_name_and_resource_type_and_resource_id"
    t.index ["resource_type", "resource_id"], name: "index_roles_on_resource"
  end

  create_table "terms", force: :cascade do |t|
    t.string "title", null: false
    t.text "content", null: false
    t.string "version", null: false
    t.integer "term_type", default: 0, null: false
    t.boolean "active", default: false, null: false
    t.text "summary"
    t.datetime "effective_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["term_type", "active"], name: "index_terms_on_term_type_and_active"
    t.index ["term_type", "version"], name: "index_terms_on_term_type_and_version"
    t.index ["version"], name: "index_terms_on_version", unique: true
  end

  create_table "user_businesses", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "business_id", null: false
    t.string "role"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id"], name: "index_user_businesses_on_business_id"
    t.index ["user_id"], name: "index_user_businesses_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "phone_number"
    t.boolean "online", default: false
    t.datetime "last_seen_at"
    t.string "provider"
    t.string "uid"
    t.string "google_image_url"
    t.datetime "confirmed_at"
    t.index ["confirmed_at"], name: "index_users_on_confirmed_at"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["online"], name: "index_users_on_online"
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true
    t.index ["provider"], name: "index_users_on_provider"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["uid"], name: "index_users_on_uid"
  end

  create_table "users_roles", id: false, force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "role_id"
    t.index ["role_id"], name: "index_users_roles_on_role_id"
    t.index ["user_id", "role_id"], name: "index_users_roles_on_user_id_and_role_id"
    t.index ["user_id"], name: "index_users_roles_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agents", "areas"
  add_foreign_key "agents", "users"
  add_foreign_key "areas", "locations"
  add_foreign_key "business_categories", "businesses"
  add_foreign_key "business_categories", "categories"
  add_foreign_key "business_invites", "businesses"
  add_foreign_key "business_invites", "users", column: "inviter_id"
  add_foreign_key "businesses", "users", column: "owner_id"
  add_foreign_key "conversation_participants", "conversations"
  add_foreign_key "conversation_participants", "users"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "users"
  add_foreign_key "mpesa_transactions", "packages"
  add_foreign_key "mpesa_transactions", "users"
  add_foreign_key "notifications", "packages"
  add_foreign_key "notifications", "users"
  add_foreign_key "package_print_logs", "packages"
  add_foreign_key "package_print_logs", "users"
  add_foreign_key "package_tracking_events", "packages"
  add_foreign_key "package_tracking_events", "users"
  add_foreign_key "packages", "agents", column: "destination_agent_id"
  add_foreign_key "packages", "agents", column: "origin_agent_id"
  add_foreign_key "packages", "areas", column: "destination_area_id"
  add_foreign_key "packages", "areas", column: "origin_area_id"
  add_foreign_key "packages", "users"
  add_foreign_key "prices", "agents", column: "destination_agent_id"
  add_foreign_key "prices", "agents", column: "origin_agent_id"
  add_foreign_key "prices", "areas", column: "destination_area_id"
  add_foreign_key "prices", "areas", column: "origin_area_id"
  add_foreign_key "push_tokens", "users"
  add_foreign_key "user_businesses", "businesses"
  add_foreign_key "user_businesses", "users"
end
