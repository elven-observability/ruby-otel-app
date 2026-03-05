# frozen_string_literal: true

class Order < ApplicationRecord
  validates :customer_id, presence: true
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :status, presence: true
end
