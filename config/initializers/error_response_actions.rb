#https://gist.github.com/abriening/1255051
# https://restpatterns.mindtouch.us/HTTP_Status_Codes
#
module ErrorResponseActions

  ERROR_RESPONSE_ACTIONS = %[authorization_error
                             unauthorized_error
                             resource_not_found
                             json_error
                             page_not_found
                             not_implmented
                             route_not_found
                             method_not_allowed
                             internal_error
                             conflict_error].freeze

  def authorization_error(exception, url = root_url)
    # 403 Forbidden response
    respond_to do |format|
      format.html {
        flash[:alert] = exception.message
        redirect_to url
      }
      format.xml {render :xml => exception.message, :status => 403}
      format.any {render :json => {:error => exception.message}.to_json, :status => 403}
    end
  end

  def unauthorized_error(exception, url = root_url)
    # 401 Unauthorized response
    respond_to do |format|
      format.html {
        flash[:alert] = exception.message
        redirect_to url
      }
      format.xml {render :xml => exception.message, :status => 401}
      format.any {render :json => {:error => exception.message}.to_json, :status => 401}
    end
  end

  def resource_not_found(exception, url = root_url)
    respond_to do |format|
      format.html {
        flash[:alert] = exception.message
        redirect_to url
      }
      format.xml {render :xml => exception.message, :status => 404}
      format.any {render :json => {:error => "not-found"}.to_json, :status => 404}
    end
  end

  def json_error(exception, url = root_url)
    respond_to do |format|
      format.html {
        flash[:alert] = exception.message
        redirect_to url
      }
      format.xml {render :xml => exception.message, :status => 400}
      format.json {render :json => {:error => "invalid-json"}.to_json, :status => 400}
    end
  end

  def internal_error(exception, url = root_url)
    respond_to do |format|
      format.html {
        flash[:alert] = "Sorry, we found an internal error [#{exception.message}] which is somewhat embarrassing, isn’t it?"
        redirect_to url
      }
      format.xml {render :xml => exception.message, :status => 500}
      format.json {render :json => {:error => "internal error[#{exception.message}]"}.to_json, :status => 500}
    end
  end

  def conflict_error(exception, url = root_url)
    respond_to do |format|
      format.html {
        flash[:alert] = exception.message
        redirect_to url
      }
      format.xml {render :xml => exception.message, :status => 409}
      format.json {render :json => {:error => "#{exception.message}"}.to_json, :status => 409}
    end
  end

end