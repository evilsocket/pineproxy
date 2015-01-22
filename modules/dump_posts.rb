class DumpPosts < PineProxy::Module
    def initialize

    end

    def is_enabled?
        return true
    end

    def on_request request, response
        if request.verb == 'POST'
            PineProxy::Logger.warn "POST REQUEST:\n\n#{request.to_s}\n"
        end
    end
end
