# frozen_string_literal: true

class InternalController < ApplicationController
  def ping
    render json: { message: "pong" }
  end
end
