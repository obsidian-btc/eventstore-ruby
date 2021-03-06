class Eventstore
  class CatchUpSubscription < Subscription
    MAX_READ_BATCH = 100

    attr_reader :es, :from, :last_backfill_event, :caught_up, :mutex

    def initialize(es, stream, from, resolve_link_tos: true)
      super(es.connection, stream, resolve_link_tos: resolve_link_tos)

      @es = es

      @from = from
      @last_backfill_event = from
      @caught_up = false

      @mutex = Mutex.new
      @received_while_backfilling = []
    end

    def on_catchup(&block)
      if block
        @on_catchup = block
      else
        @on_catchup.call() if @on_catchup
      end
    end

    def start
      subscribe
      loop do
        is_end_of_stream = backfill
        break if is_end_of_stream
      end
      switch_to_live
      on_catchup()
    end

    def event_appeared(event)
      # puts fn: "event_appeared", caught_up: caught_up,  event_number: event.event.event_number
      unless caught_up
        mutex.synchronize do
          unless caught_up
            @received_while_backfilling << event
          end
        end
      end
      if caught_up
        on_event(event)
      end
    end

    private

    def backfill
      # puts "fn=backfill stream=#{stream} at=page_start last_backfill_event=#{last_backfill_event}"
      prom = es.read_stream_events_forward(stream, last_backfill_event + 1, MAX_READ_BATCH)
      response = prom.sync
      #puts "fn=backfill stream=#{stream} at=received"
      # p response
      mutex.synchronize do
        Array(response.events).each { |event|
          on_event(event)
          @last_backfill_event = event.event.event_number
        }
      end
      # puts "fn=backfill stream=#{stream} at=page_done"
      return response.is_end_of_stream
    end

    def switch_to_live
      # puts "fn=switch_to_live"
      mutex.synchronize do
        @received_while_backfilling.each do |event|
          if event.event.event_number > @last_backfill_event
            # puts fn: "event_at_switch", event_number: event.event.event_number
            on_event(event)
          end
        end
        @caught_up = true
      end
    end
  end
end
