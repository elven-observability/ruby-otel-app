# frozen_string_literal: true

class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.string :customer_id, null: false
      t.integer :amount_cents, null: false
      t.string :status, null: false, default: "processing"

      t.timestamps
    end
  end
end
