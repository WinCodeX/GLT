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

ActiveRecord::Schema[7.1].define(version: 2025_08_14_055146) do
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

  create_table "areas", force: :cascade do |t|
    t.string "name"
    t.bigint "location_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "initials", limit: 3
    t.index ["initials"], name: "idx_areas_initials", unique: true
    t.index ["location_id"], name: "index_areas_on_location_id"
  end

  create_table "businesses", force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.bigint "owner_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id"], name: "index_businesses_on_owner_id"
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
    t.index ["code"], name: "idx_packages_code", unique: true
    t.index ["destination_agent_id"], name: "index_packages_on_destination_agent_id"
    t.index ["destination_area_id"], name: "index_packages_on_destination_area_id"
    t.index ["origin_agent_id"], name: "index_packages_on_origin_agent_id"
    t.index ["origin_area_id", "destination_area_id", "route_sequence"], name: "idx_packages_route_seq"
    t.index ["origin_area_id"], name: "index_packages_on_origin_area_id"
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
    t.index ["destination_agent_id"], name: "index_prices_on_destination_agent_id"
    t.index ["destination_area_id"], name: "index_prices_on_destination_area_id"
    t.index ["origin_agent_id"], name: "index_prices_on_origin_agent_id"
    t.index ["origin_area_id"], name: "index_prices_on_origin_area_id"
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
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["online"], name: "index_users_on_online"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
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
  add_foreign_key "businesses", "users", column: "owner_id"
  add_foreign_key "conversation_participants", "conversations"
  add_foreign_key "conversation_participants", "users"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "users"
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
  add_foreign_key "user_businesses", "businesses"
  add_foreign_key "user_businesses", "users"
end
