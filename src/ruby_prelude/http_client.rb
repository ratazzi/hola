# Simple HTTP client
class HolaHttp
  class Response
    attr_reader :status, :headers, :body

    def initialize(status, headers, body)
      @status = status
      @headers = headers
      @body = body
    end

    def success?
      status >= 200 && status < 300
    end

    def json
      @json ||= JSON.parse(body)
    end

    def to_s
      body
    end
  end

  # GET request with optional headers
  # headers can be a Hash or Array of [key, value] pairs
  def self.get(url, headers = nil)
    headers_arr = normalize_headers(headers)
    result = ZigBackend.http_get(url, headers_arr)
    Response.new(result[0], result[1], result[2])
  end

  # POST request with optional body, content_type, and headers
  def self.post(url, body = nil, content_type = nil, headers = nil)
    headers_arr = normalize_headers(headers)
    result = ZigBackend.http_post(url, body || "", content_type || "application/x-www-form-urlencoded", headers_arr)
    Response.new(result[0], result[1], result[2])
  end

  # PUT request with optional body, content_type, and headers
  def self.put(url, headers = nil, body = nil, content_type = nil)
    # For PUT requests, often headers come first (especially for authentication)
    # But we also support the old signature for compatibility
    if headers.is_a?(String)
      # Old signature: put(url, body, content_type, headers)
      body, content_type, headers = headers, body, content_type
    end

    headers_arr = normalize_headers(headers)
    result = ZigBackend.http_put(url, body || "", content_type || "application/json", headers_arr)
    Response.new(result[0], result[1], result[2])
  end

  # DELETE request with optional headers
  def self.delete(url, headers = nil)
    headers_arr = normalize_headers(headers)
    result = ZigBackend.http_delete(url, headers_arr)
    Response.new(result[0], result[1], result[2])
  end

  # PATCH request with optional body, content_type, and headers
  def self.patch(url, body = nil, content_type = nil, headers = nil)
    headers_arr = normalize_headers(headers)
    result = ZigBackend.http_patch(url, body || "", content_type || "application/json", headers_arr)
    Response.new(result[0], result[1], result[2])
  end

  private

  def self.normalize_headers(headers)
    return nil if headers.nil?
    if headers.is_a?(Hash)
      headers.map { |k, v| [k.to_s, v.to_s] }
    else
      headers
    end
  end
end
