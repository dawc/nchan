#!/usr/bin/env ruby
require 'rubygems'
require 'bundler/setup'

require 'minitest'
require 'minitest/reporters'
require "minitest/autorun"
Minitest::Reporters.use! [Minitest::Reporters::SpecReporter.new(:color => true)]
require 'securerandom'
require_relative 'pubsub.rb'
require_relative 'authserver.rb'
require "optparse"
require 'digest/sha1'

$server_url="http://127.0.0.1:8082"
$default_client=:longpoll
$omit_longmsg=false
$verbose=false

extra_opts = []
orig_args = ARGV.dup

opt=OptionParser.new do |opts|
  opts.on("--server SERVER (#{$server_url})", "server url."){|v| $server_url=v}
  opts.on("--default-subscriber TRANSPORT (#{$default_client})", "default subscriber type"){|v| $default_client=v.to_sym}
  opts.on("--verbose", "set Accept header") do |v| 
    verbose = true
    Typhoeus::Config.verbose = true
  end
  opts.on("--omit-longmsg", "skip long-message tests"){$omit_longmsg = true}
  opts.on_tail('-h', '--help', 'Show this message!!!!') do
    puts opts
    raise OptionParser::InvalidOption , "--help"
  end
end

begin
  opt.parse!(ARGV)
rescue OptionParser::InvalidOption => e
  extra_opts << e.args
  retry
end

(orig_args & ( ARGV | extra_opts.flatten )).each { |arg| ARGV << arg }

def short_id
  SecureRandom.hex.to_i(16).to_s(36)[0..5]
end

def url(part="")
  part=part[1..-1] if part[0]=="/"
  "#{$server_url}/#{part}"
end
puts "Server at #{url}"
def pubsub(concurrent_clients=1, opt={})
  test_name = caller_locations(1,1)[0].label
  urlpart=opt[:urlpart] || 'broadcast'
  timeout = opt[:timeout]
  sub_url=opt[:sub] || "sub/broadcast/"
  pub_url=opt[:pub] || "pub/"
  chan_id = opt[:channel] || short_id
  sub = Subscriber.new url("#{sub_url}#{chan_id}?test=#{test_name}#{opt[:sub_param] ? "&#{URI.encode_www_form(opt[:sub_param])}" : ""}"), concurrent_clients, timeout: timeout, use_message_id: opt[:use_message_id], quit_message: 'FIN', gzip: opt[:gzip], retry_delay: opt[:retry_delay], client: opt[:client] || $default_client, extra_headers: opt[:extra_headers], verbose: opt[:verbose] || $verbose, permessage_deflate: opt[:permessage_deflate], subprotocol: opt[:subprotocol]
  pub = Publisher.new url("#{pub_url}#{chan_id}?test=#{test_name}#{opt[:pub_param] ? "&#{URI.encode_www_form(opt[:pub_param])}" : ""}"), timeout: timeout, websocket: opt[:websocket_publisher]
  return pub, sub
end
def verify(pub, sub, check_errors=true)
  assert sub.errors.empty?, "There were subscriber errors: \r\n#{sub.errors.join "\r\n"} (sub url #{sub.url})" if check_errors
  if pub then
    ret, err = sub.messages.matches?(pub.messages)
    assert ret, err ? "#{err} (sub url #{sub.url})" : "Messages don't match (sub url #{sub.url})"
  end
  i=0
  sub.messages.each do |msg|
    assert_equal sub.concurrency, msg.times_seen, "Concurrent subscribers didn't all receive message #{i} (sub url #{sub.url})"
    i+=1
  end
end

class PubSubTest <  Minitest::Test
  def setup
    Celluloid.boot
  end
  
  def test_interval_poll
    pub, sub=pubsub 1, sub: "/sub/intervalpoll/", client: :intervalpoll, quit_message: 'FIN', retry_delay: 0.5
    ws_sub=Subscriber.new(sub.url, 1, client: :websocket, quit_message: 'FIN')

    got_304s=0
    sub.on_failure do |msg|
      got_304s += 1
      assert_match /code 304/, msg #handshake will be treated as intervalpoll client?...
    end
    
    ws_sub.run
    sub.run

    sleep 0.4
    
    #binding.pry
    assert ws_sub.match_errors(/403/), "expected 403 for all non-intervalpoll subscribers, got #{ws_sub.errors.pretty_inspect}"
    ws_sub.terminate
    
    pub.post ["hello this", "is a thing"]
    sleep 0.3
    pub.post ["oh now what", "is this even a thing?"]
    sleep 0.1
    
    sleep 1.5
    
    pub.post "yoo"
    pub.post "FIN"
    
    sub.wait

    verify pub, sub
    sub.terminate
    assert got_304s > 0, "Expected at least one 304 response"
  end
  
  def test_weird_msgids
    
    #multi-msgid in nonmulti channel
    pub, sub = pubsub
    pub.post ['hey there', "banana", "huh", "notweird", "FIN"]
    sub.on_failure { false }
    sub.on_message do |msg, bundle|
      bundle.etag="#{bundle.etag},99,110"
    end
    sub.run
    sub.wait
    assert sub.match_errors(/code 400/), "expected 400 for subscriber"
    sub.terminate
    
    #255-count msgid
    pub, sub = pubsub
    pub.post ['hey there', "banana", "huh", "notweird", "FIN"]
    sub.on_failure { false }
    sub.on_message do |msg, bundle|
      bundle.etag=(0..255).to_a.join ","
    end
    sub.run
    sub.wait
    assert sub.match_errors(/code 400/), "expected 400 for subscriber"
    sub.terminate
    
    #many tagactives
    pub, sub = pubsub
    
    pub.post ['hey there', "banana", "huh", "notweird", "FIN"]
    
    sub.on_failure { false }
    
    sub.on_message { |msg, bundle| bundle.etag="[[[0,13,[9],[11]]]]" }
    sub.run
    sub.wait
    #puts sub.errors
    assert sub.match_errors(/code 400/), "expected 400 for subscriber"
    sub.terminate
    
    #messed up tagactive
    pub, sub = pubsub
    pub.post ['hey there', "banana", "huh", "notweird", "FIN"]
    sub.on_failure { false }
    sub.on_message do |msg, bundle|
      bundle.etag="0,13,[9]]"
    end
    sub.run
    sub.wait
    assert sub.match_errors(/code 400/), "expected 400 for subscriber"
    sub.terminate
    
    #multiplexed channel stuff
    chan_id=short_id
    pub = Publisher.new url("/pub/#{chan_id}"), accept: 'text/json'
    pub.post ['hey there', "banana", "huh", "notweird", "FIN"]
    
    #first request with non-empty msgtags
    sub = Subscriber.new(url("/sub/multi/#{short_id}/#{short_id}/#{chan_id}"), 1, quit_message: 'FIN', retry_delay: 1, timeout: 20, etag: "10,20,30")
    sub.on_failure { false }
    sub.run
    sub.wait
    assert sub.match_errors(/code 400/), "expected 400 for subscriber"
    sub.terminate
    
    #wrong msgid count
    sub = Subscriber.new(url("/sub/multi/#{short_id}/#{short_id}/#{chan_id}"), 1, quit_message: 'FIN', retry_delay: 1, timeout: 20)
    sub.on_failure { false }
    sub.on_message do |msg, bundle|
      bundle.etag="#{bundle.etag},99,110"
    end
    sub.run
    sub.wait
    assert sub.match_errors(/code 400/), "expected 400 for subscriber"
    sub.terminate
    
    #now check that a normal sub works okay
    sub = Subscriber.new(url("/sub/multi/#{short_id}/#{short_id}/#{chan_id}"), 10, quit_message: 'FIN', retry_delay: 1, timeout: 20)
    sub.run
    sub.wait
    verify pub, sub
    
  end
  
  def test_websocket_pubsub_echo
    sub=Subscriber.new(url("/pubsub/#{short_id}"), 1, client: :websocket, quit_message: 'FIN')
    
    sub.run
    sub.wait :ready
    
    msgs = ['hello', 'FIN']
    
    sub.client.send_data msgs[0]
    sub.client.send_data msgs[1]
    
    sub.wait
    
    verify nil, sub
    
    sub.messages.msgs.each_with_index do |msg, i|
      assert_equal msg.times_seen, 1
      assert_equal msg.message, msgs[i]
    end
    
    sub.terminate
  end
  
  def test_websocket_publish
    pub, sub = pubsub 5, websocket_publisher: true
    #pub.on_response do |code, resp_body|
    #  puts "====----====="
    #  puts resp_body
    #end
    sub.run #celluloid async FTW
    ["!!!!", "nothing at all really",  "FIN"].each do |msg|
      sleep 0.1
      pub.post msg
    end
    sub.wait
    verify pub, sub
    sub.terminate
    pub.terminate #kill websocket publisher
  end
  
  def test_channel_info
    require 'json'
    require 'nokogiri'
    require 'yaml'
    
    subs=20
    
    chan=SecureRandom.hex
    pub, sub = pubsub(subs, channel: chan, client: :eventsource)
    pub.nofail=true
    pub.get
    assert_equal 404, pub.response_code
    
    pub.post ["hello", "what is this i don't even"]
    assert_equal 202, pub.response_code
    pub.get
    
    assert_equal 200, pub.response_code
    assert_match /last requested: -?\d+ sec/, pub.response_body
    
    pub.get "text/json"
    
    info_json=JSON.parse pub.response_body
    assert_equal 2, info_json["messages"]
    #assert_equal 0, info_json["requested"]
    assert_equal 0, info_json["subscribers"]

    
    sub.run
    sub.wait :ready
    sleep 0.15
    pub.get "text/json"

    info_json=JSON.parse pub.response_body
    assert_equal 2, info_json["messages"]
    #assert_equal 0, info_json["requested"]
    assert_equal subs, info_json["subscribers"], "text/json subscriber count"

    pub.get "text/xml"
    ix = Nokogiri::XML pub.response_body
    assert_equal 2, ix.at_xpath('//messages').content.to_i
    #assert_equal 0, ix.at_xpath('//requested').content.to_i
    assert_equal subs, ix.at_xpath('//subscribers').content.to_i
    
    pub.get "text/yaml"
    yaml_resp1=pub.response_body
    pub.get "application/yaml"
    yaml_resp2=pub.response_body
    pub.get "application/x-yaml"
    yaml_resp3=pub.response_body
    yam=YAML.load pub.response_body
    assert_equal 2, yam["messages"]
    #assert_equal 0, yam["requested"]
    assert_equal subs, yam["subscribers"]
    
    assert_equal yaml_resp1, yaml_resp2
    assert_equal yaml_resp2, yaml_resp3
    
    
    pub.accept="text/json"

    pub.post "FIN"
    #stats right before FIN was issued
    info_json=JSON.parse pub.response_body
    assert_equal 3, info_json["messages"]
    #assert_equal 0, info_json["requested"]
    assert_equal subs, info_json["subscribers"]
    
    sub.wait
    sleep 0.5
    
    pub.get "text/json"
    info_json=JSON.parse pub.response_body
    assert_equal 3, info_json["messages"], "number of messages received by channel is wrong"
    #assert_equal 0, info_json["requested"]
    assert_equal 0, info_json["subscribers"], "channel should say there are no subscribers"
    
    sub.terminate
  end
  
  def multi_sub_url(pubs, prefix="/sub/multi/", delim="/")
    ids = pubs.map{|v| v.id}.shuffle
    "#{prefix}#{ids.join delim}"
  end
  
  class MultiCheck
    attr_accessor :id, :pub
    def initialize(id)
      self.id = id
      self.pub = Publisher.new url("/pub/#{self.id}")
    end
  end
  
  
  def test_channel_multiplexing(n=2, delimited=false)
    
    pubs = []
    n.times do |i|
      pubs << MultiCheck.new(short_id)
    end
    
    sub_url=delimited ? multi_sub_url(pubs, '/sub/split/', '_') : multi_sub_url(pubs)
    
    n = 15
    scrambles = 5
    subs = []
    scrambles.times do |i|
      sub = Subscriber.new(url("#{sub_url}?meh=#{short_id}"), n, quit_message: 'FIN', retry_delay: 1, timeout: 20)
      sub.on_failure { false }
      subs << sub
    end
    
    subs.each &:run
    
    pubs.each {|p| p.pub.post "FIRST from #{p.id}" }
    
    10.times do |i|
      pubs.each {|p| p.pub.post "hello #{i} from #{p.id}" }
    end
    
    sleep 1
    
    5.times do |i|
      pubs.first.pub.post "yes #{i} from #{pubs.first.id}"
    end
    
    pubs.each do |p| 
      10.times do |i|
        p.pub.post "hello #{i} from #{p.id}"
      end
    end
    
    latesubs = Subscriber.new(url("#{sub_url}?late&meh=#{short_id}"), n, quit_message: 'FIN')
    latesubs.on_failure { false }
    subs << latesubs
    latesubs.run
    
    sleep 1
    
    10.times do |i|
      pubs.each {|p| p.pub.post "hello again #{i} from #{p.id}" }
    end
    
    pubs.first.pub.post "FIN"
    subs.each &:wait
    sleep 1
    subs.each_with_index do |sub, sub_i|
      
      assert_equal 0, sub.errors.count, "Subscriber encountered #{sub.errors.count} errors: #{sub.errors.join ", "}"
      
      msgs=[]
      pubs.each { |p| msgs << p.pub.messages.messages }
      
      sub.messages.each do |msg|  
        matched = false
        for mm in msgs do
          if mm.first == msg.message
            matched = true
            mm.shift
            break
          end
        end
        assert_equal matched, true, "message not matched, sub url #{sub.url}"
      end
      
      sub.terminate
    end
    
  end
  
  def test_channel_multiplexing_5
    test_channel_multiplexing 5
  end
  
  def test_channel_delimitered_multiplexing_15
    test_channel_multiplexing 15, true
  end
  
  def test_message_delivery
    pub, sub = pubsub
    sub.run
    sleep 0.2
    assert_equal 0, sub.messages.messages.count
    pub.post "hi there"
    assert_equal 201, pub.response_code, "publisher response code"
    sleep 0.2
    assert_equal 1, sub.messages.messages.count, "received message count"
    pub.post "FIN"
    assert_equal 201, pub.response_code, "publisher response code"
    sleep 0.2
    assert_equal 2, sub.messages.messages.count, "recelived messages count"
    assert sub.messages.matches? pub.messages
    sub.terminate
  end
  
  def test_publish_then_subscribe
    pub, sub = pubsub
    pub.post "hi there"
    sub.run
    pub.post "FIN"
    sub.wait
    assert_equal 2, sub.messages.messages.count
    assert sub.messages.matches? pub.messages
    sub.terminate
  end

  def test_preexisting_channels
    #must be published to before subscribing
    n=5
    pub, sub = pubsub n, timeout: 6, sub: "sub/preexisting/"
    sub.on_failure { false }
    sub.run
    sleep 1
    sub.wait
    assert_equal n, sub.finished
    
    assert sub.match_errors(/code 403/), "expected 403 for all subscribers, got #{sub.errors.pretty_inspect}"
    sub.reset
    
    pub.post %w( fweep )
    assert_match /20[12]/, pub.response_code.to_s
    sleep 0.1
    
    sub.run
    
    sleep 0.1
    pub.post ["fwoop", "FIN"] { assert_match /20[12]/, pub.response_code.to_s }
    
    
    sub.wait
    verify pub, sub
    sub.terminate
  end

  def test_delete
    #delete active channel
    par=5
    pub, sub = pubsub par, timeout: 10
    sub.on_failure { false }
    sub.run
    sleep 0.2
    pub.delete
    sleep 0.1
    assert_equal 200, pub.response_code
    assert_equal par, pub.response_body.match(/subscribers:\s+(\d)/)[1].to_i, "subscriber count after deletion"
    sub.wait
    assert sub.match_errors(/code 410/), "Expected subscriber code 410: Gone, instead was \"#{sub.errors.first}\""
    sub.terminate

    #delete channel with no subscribers
    pub, sub = pubsub 5, timeout: 1
    pub.post "hello"
    assert_equal 202, pub.response_code
    pub.delete
    assert_equal 200, pub.response_code

    #delete nonexistent channel
    pub, sub = pubsub
    pub.nofail=true
    pub.delete
    assert_equal 404, pub.response_code
    sub.terminate
  end

  def test_no_message_buffer
    chan_id=SecureRandom.hex
    pub = Publisher.new url("/pub/nobuffer/#{chan_id}")
    sub=[]
    40.times do 
      sub.push Subscriber.new(url("/sub/broadcast/#{chan_id}"), 1, use_message_id: false, quit_message: 'FIN')
    end
    
    pub.post ["this message should not be delivered", "nor this one"]
    
    sub.each {|s| s.run}
    sleep 1
    pub.post "received1"
    sleep 1
    pub.post "received2"
    sleep 1
    pub.post "FIN"
    sub.each &:wait
    sub.each do |s|
      assert s.errors.empty?, "There were subscriber errors: \r\n#{s.errors.join "\r\n"}"
      ret, err = s.messages.matches? ["received1", "received2", "FIN"]
      assert ret, err || "Messages don't match"
    end
    sub.each &:terminate
  end
  
  def test_channel_isolation
    rands= %w( foo bar baz bax qqqqqqqqqqqqqqqqqqq eleven andsoon andsoforth feh )
    pub=[]
    sub=[]
    10.times do |i|
      pub[i], sub[i]=pubsub 15
      sub[i].run
    end
    pub.each do |p|
      rand(1..10).times do
        p.post rands.sample
      end
    end
    sleep 1
    pub.each do |p|
      p.post 'FIN'
    end
    sub.each do |s|
      s.wait
    end
    pub.each_with_index do |p, i|
      verify p, sub[i]
    end
    sub.each &:terminate
  end
  
  def test_broadcast_3
    test_broadcast 3
  end
  
  def test_broadcast_20
    test_broadcast 20
  end
  
  def test_longpoll_multipart
    pub, sub = pubsub 1, sub: 'sub/multipart/', use_message_id: false
    
    pub.post "first", "text/x-foobar"
    pub.post ["1", "2", "3", "4", "beeeeeeeeeeeeeeeeeeeeeeeee", "", "foobar"]
    pub.post "", "text/x-banana"
    sub.run
    sleep 0.5
    pub.post "FIN"
    sub.wait
   
    verify pub, sub
    sub.terminate
  end
  
  def test_longpoll_multipart_extended(range=30..35)
    range.each do |i|
      pub, sub = pubsub 1, sub: 'sub/multipart/', use_message_id: false, timeout: 3
      i.times do |n|
        pub.post "#{n+1}"
      end
      pub.post "FIN"
      sub.run
      sub.wait
      verify pub, sub
      sub.terminate
      sleep 0.1
    end
  end
  
  def test_multiplexed_longpoll_multipart
    chans= [short_id, short_id, short_id]
    pub, sub = pubsub 1, sub: "sub/multipart_multiplex/#{chans.join "/"}", pub: "pub/#{chans[1]}", channel: "", use_message_id: false
    
    pub.post "first", "text/x-foobar"
    pub.post ["1", "2", "3", "4"]
    sub.run
    sleep 0.5
    pub.post "FIN"
    sub.wait
   
    verify pub, sub
    sub.terminate
  end
  
  
  def test_broadcast(clients=400, pubsub_opt={}, opt={})
    pub, sub = pubsub clients, pubsub_opt
    pub.post "!!", opt[:content_type]
    sub.run #celluloid async FTW
    #sleep 2
    pub.post ["!!!!", "what is this", "it's nothing", "nothing at all really"], opt[:content_type]
    pub.post "FIN", opt[:content_type]
    
    sub.wait
    sleep 0.5
    
    sub.messages.each do |msg|
      if opt[:must_have_message_ids]
        assert msg.id, "message id must be present, but isn't"
      elsif opt[:must_have_message_ids] == false
        assert_nil msg.id, "message_id must be absent, but isn't"
      end
      
      if opt[:must_have_content_type]
        assert msg.content_type, "message content-type must be present, but isn't"
        assert_equal opt[:content_type], msg.content_type, "message content type doesn't match"
      elsif opt[:must_have_content_type]==false
        assert_nil msg.content_type, "message content-type must be absent, but isn't"
      end
    end
    
    if opt[:must_use_permessage_deflate]
      binding.pry
    end
    
    verify pub, sub
    sub.terminate
  end
  
  #def test_broadcast_10000
  #  test_broadcast 10000
  #end
  
  def dont_test_subscriber_concurrency
    chan=SecureRandom.hex
    pub_first = Publisher.new url("pub/first#{chan}")
    pub_last = Publisher.new url("pub/last#{chan}")
    
    sub_first, sub_last = [], []
    { url("sub/first/first#{chan}") => sub_first, url("sub/last/last#{chan}") => sub_last }.each do |url, arr|
      3.times do
        sub=Subscriber.new(url, 1, quit_message: 'FIN', timeout: 20)
        sub.on_failure do |resp, req|
          false
        end
        arr << sub
      end
    end
    
    sub_first.each {|s| s.run; sleep 0.1 }
    assert sub_first[0].no_errors?
    sub_first[1..2].each do |s|
      assert s.errors?
      assert s.match_errors(/code 409/)
    end

    sub_last.each {|s| s.run; sleep 0.1 }
    assert sub_last[2].no_errors?
    sub_last[0..1].each do |s|
      assert s.errors?
      assert s.match_errors(/code 40[49]/)
    end

    pub_first.post %w( foo bar FIN )
    pub_last.post %w( foobar baz somethingelse FIN )
    
    sub_first[0].wait
    sub_last[2].wait
    
    verify pub_first, sub_first[0]
    verify pub_last, sub_last[2]
    
    sub_first[1..2].each{ |s| assert s.messages.count == 0 }
    sub_last[0..1].each{ |s| assert s.messages.count == 0 }
    [sub_first, sub_last].each {|sub| sub.each{|s| s.terminate}}
  end

  def test_queueing
    pub, sub = pubsub 1
    pub.post %w( what is this_thing andnow 555555555555555555555 eleven FIN ), 'text/plain'
    sleep 0.3
    sub.run
    sub.wait
    verify pub, sub
    sub.terminate
  end
  
  def test_long_message(kb=0.5)
    pub, sub = pubsub 10, timeout: 10
    sub.run
    sleep 0.2
    pub.post ["#{"q"*((kb * 1024)-3)}end", "FIN"]
    sub.wait
    verify pub, sub
    sub.terminate
  end
  
  unless $omit_longmsg
    #[5, 9, 9.5, 9.9, 10, 11, 15, 16, 17, 18, 19, 20, 30,  50, 100, 200, 300, 600, 900, 3000].each do |n|
    [5, 10, 20, 200, 900].each do |n|
      define_method "test_long_message_#{n}Kb" do 
        test_long_message n
      end
    end
    
    def test_message_length_range
      pub, sub = pubsub 2, timeout: 15
      sub.run
      
      n=5
      while n <= 10000 do
        pub.post "T" * n
        n=(n*1.01) + 1
        sleep 0.001
      end
      pub.post "FIN"
      sub.wait
      verify pub, sub
      sub.terminate
    end
    
    def generic_test_long_buffed_messages(client=:longpoll)
      kb=2000
      #kb=2
      pub, sub = pubsub 1, sub: "/sub/broadcast/", timeout: 10, client: client
      #pub, sub = pubsub 1, sub: "/sub/websocket_only/", client: :websocket
      #sub.on_message do |msg|
      #  puts ">>>>>>>message: #{msg.message[0...10]}...|#{msg.message.length}|"
      #end
      sub.run
      sleep 1
      m1="#{"q"*((kb * 1024)-3)}end"
      m2="#{"r"*((kb * 1024)-3)}end"
      i=0
      15.times do
        i+=1
        pub.post "#{i}#{m1}"
        i+=1
        pub.post "#{i}#{m2}"
      end
      pub.post "FIN"
      sub.wait
      verify pub, sub
      pub.delete
      sub.terminate
    end

    [:longpoll, :multipart, :eventsource, :websocket, :chunked].each do |client|
      define_method "test_long_buffed_messages_#{client}" do
        generic_test_long_buffed_messages client
      end
    end
    
  end
  
  def test_message_timeout
    pub, sub = pubsub 1, pub: "/pub/2_sec_message_timeout/", timeout: 10
    pub.post %w( foo bar etcetera ) #these shouldn't get delivered
    pub.messages.clear
    sleep 3
    #binding.pry
    sub.run
    sleep 1
    pub.post %w( what is this even FIN )
    sub.wait
    verify pub, sub
    sub.terminate
  end
  
  
  
  def test_publish_multi
    chans= [short_id, short_id, short_id]
    subs= chans.map do |id|
      Subscriber.new url("sub/broadcast/#{id}"), 2, client: :eventsource, quit_message: 'FIN'
    end
    pub = Publisher.new url("pub_multi/#{chans.join '/'}")
    
    subs.each &:run
    pub.post ["hey", "thing", "did it", "FIN"]
    
    subs.each &:wait
    
    subs.each do |sub|
      verify pub, sub
      sub.terminate
    end
  end
  
    def test_delete_multi
    chans= [short_id, short_id, short_id]
    keeper = short_id
    subs= chans.map do |id|
      Subscriber.new url("sub/broadcast/#{id}"), 2, client: :eventsource, quit_message: 'FIN'
    end
    
    subs << Subscriber.new(url("sub/multi/#{chans[0]}/#{keeper}"), 2, client: :eventsource, quit_message: 'FIN')
    
    
    pub_keep, sub_keep = pubsub 1, channel: keeper, timeout: 10
    
    pub = Publisher.new url("pub_multi/#{chans.join '/'}")
    
    sub_keep.run
    subs.each &:run
    
    pub.post ["hey", "thing", "did it"]
    sleep 1
    pub.delete
    
    pub_keep.post ["yeah this", "it's a thing, too"]
    
    subs.each &:wait
    
    subs.each do |sub|
      assert sub.match_errors(/code 410/), "Expected subscriber code 410: Gone, instead was \"#{sub.errors.first}\""
      sub.errors.clear
      verify pub, sub
    end
    
    pub_keep.post ["also this", "FIN"]
    sub_keep.wait
    verify pub_keep, sub_keep
    
    subs.each &:terminate
    sub_keep.terminate
  end
  
  def test_subscriber_timeout
    chan=SecureRandom.hex
    sub=Subscriber.new(url("sub/timeout/#{chan}"), 5, timeout: 10)
    sub.on_failure { false }
    pub=Publisher.new url("pub/#{chan}")
    sub.run
    sleep 0.1
    pub.post "hello"
    sub.wait
    verify pub, sub, false
    assert sub.match_errors(/code 408/)
    sub.terminate
  end
  
  def assert_header_includes(response, header, str)
    assert response.headers[header].include?(str), "Response header '#{header}: #{response.headers[header]}' must contain \"#{str}\", but does not."
  end
  
  def test_access_control_options
    chan=SecureRandom.hex
    
    request = Typhoeus::Request.new url("sub/broadcast/#{chan}"), method: :OPTIONS, headers: { 'Origin' =>'http://example.com' }
    resp = request.run
    
    assert_equal "http://example.com", resp.headers["Access-Control-Allow-Origin"]
    %w( GET ).each do |v| 
      assert_header_includes resp, "Access-Control-Allow-Methods", v
      assert_header_includes resp, "Allow", v
    end
    %w( If-None-Match If-Modified-Since Content-Type Cache-Control X-EventSource-Event ).each {|v| assert_header_includes resp, "Access-Control-Allow-Headers", v}
    
    request = Typhoeus::Request.new url("sub/broadcast/#{chan}"), method: :OPTIONS
    resp = request.run
    %w( GET ).each do |v| 
      assert_header_includes resp, "Allow", v
    end
    
    
    request = Typhoeus::Request.new url("pub/#{chan}"), method: :OPTIONS, headers: { 'Origin' => "https://example.com" }
    resp = request.run
    assert_equal "https://example.com", resp.headers["Access-Control-Allow-Origin"]
    %w( GET POST DELETE ).each do |v| 
      assert_header_includes resp, "Access-Control-Allow-Methods", v
      assert_header_includes resp, "Allow", v
    end
    %w( Content-Type ).each {|v| assert_header_includes resp, "Access-Control-Allow-Headers", v}
    
    request = Typhoeus::Request.new url("pub/#{chan}"), method: :OPTIONS
    resp = request.run
    %w( GET POST DELETE ).each do |v| 
      assert_header_includes resp, "Allow", v
    end
  end
  
  def generic_test_access_control(opt)
    pub, sub = pubsub 1, extra_headers: { Origin: opt[:origin] }, pub: opt[:pub_url], sub: opt[:sub_url], sub_param: opt[:param], pub_param: opt[:param]
    
    sub.on_message do |msg, bundle|
      opt[:verify_sub_response].call(bundle) if opt[:verify_sub_response]
    end
    
    if opt[:on_failure]
      sub.on_failure do |err, bundle|
        opt[:on_failure].call(err, bundle)
      end
    end
    
    pub.post "FIN"
    sub.run
    sub.wait
    
    yield pub, sub if block_given?
    
    sub.terminate
  end
  
  #def test_urlencoded_channel_id
  #  chan_id="#{short_id}_thing"
  #  pub = Publisher.new url("/pub/#{chan_id}"), accept: 'text/json'
  #  sub = Subscriber.new(url("/sub/split/#{URI.encode(chan_id, "_")}"), 1, quit_message: 'FIN', retry_delay: 1, timeout: 20)
  #  
  #  sub.run
  #  pub.post ["hey what", "okay", "FIN"]
  #  sub.wait
  #  
  #  verify pub, sub
  #  
  #end
  
  def test_urlencoded_msgid
    chan_id=short_id
    pub = Publisher.new url("/pub/#{chan_id}"), accept: 'text/json'
    
    pub.post 'heyo'
    pub.messages.clear
    resp = pub.post 'FIN'
    
    info = JSON.parse resp.body
    last_msgid_time = info["last_message_id"].match(/\d+/).to_s
    

    last_msgid = "#{last_msgid_time}%3A-%2C-%2C%5B0%5D%2C-"
    
    sub = Subscriber.new(url("/sub/split/#{short_id}_#{short_id}_#{chan_id}_#{short_id}?last_event_id=#{last_msgid}"), 1, quit_message: 'FIN', retry_delay: 1, timeout: 20)
    sub.run
    sub.wait
    
    sub2 = Subscriber.new(url("/sub/split/#{short_id}_#{short_id}_#{chan_id}_#{short_id}?last_event_id=#{URI.decode last_msgid}"), 1, quit_message: 'FIN', retry_delay: 1, timeout: 20)
    sub2.run
    sub2.wait
    
    verify pub, sub
    verify pub, sub2
  end
  
  def test_invalid_etag
    chan_id=short_id
    pub = Publisher.new url("/pub/#{chan_id}"), accept: 'text/json'
    
    pub.post "1. one!!"
    sleep 1
    pub.post "2. tooo"
    pub.post "3. throo"
    sleep 1
    pub.post "4. fooo"
    n = 0
    sub = Subscriber.new(url("/sub/multipart_multiplex/#{short_id}/#{short_id}/#{chan_id}"), 1, quit_message: 'FIN', retry_delay: 1, timeout: 20)
    sub.on_message do |msg, bundle|
      n=n+1
      if n == 2
        bundle.etag="null"
      end
    end
    
    sub.on_failure do |err|
      assert_match /code 400/, err
      false
    end
    
    sub.run
    sleep 1
    pub.post "5. faaa"
    pub.post "FIN"
    sub.wait
    sub.terminate
  end
  
  def test_missing_message_tag
    chan_id=short_id
    pub = Publisher.new url("/pub/#{chan_id}"), accept: 'text/json'
    
    pub.post "1. one!!"
    pub.post "2. tooo"
    pub.post "3. throo"
    sleep 1
    pub.post "4. fooo"
    n = 0
    
    subs = ["/sub/multi/#{short_id}/#{short_id}/#{chan_id}", "/sub/broadcast/#{chan_id}"].map do |path|
    
      sub = Subscriber.new(url(path), 1, quit_message: 'FIN', retry_delay: 1, timeout: 5)
    
      first_msg = nil
      sub.on_message do |msg, bundle|  
        bundle.etag=nil
        if first_msg
          assert( msg.message == first_msg.message && msg.id == first_msg.id)
          false
        else
          first_msg = msg
        end
      end
      
      sub.on_failure do |err|
        assert_match /code 400/, err
        false
      end
      
      sub
    end
    
    
    subs.each &:run
    subs.each &:wait
    subs.each &:terminate
  end
  
  
  def test_empty_message
    chan_id=short_id
    pub = Publisher.new url("/pub/#{chan_id}?test=test_empty_message")
    subs = [:longpoll, :eventsource, :websocket, :multipart, :chunked].map do |type|
      Subscriber.new(url("/sub/broadcast/#{chan_id}?test=test_test_empty_message"), 1, quit_message: 'FIN', retry_delay: 2, client: type, timeout: 10)
    end
    subs.each do |s| 
      s.on_failure {false}
      s.run
    end
    pub.post ["hey", "here's a blank...", "", "", "one more", "", "ok then", "FIN"]
    subs.each &:wait
    subs.each do |sub|
      if Subscriber::HTTPChunkedClient === sub.client
        #chunked clients don't receive blank messages
        nonempty = pub.messages.select{|m| m.message.length != 0}
        assert sub.errors.empty?
        ret, err = sub.messages.matches?(nonempty)
        assert ret, err ? "#{sub.client}: #{err}" : "#{sub.client}: Messages don't match"
        i=0
        sub.messages.each do |msg|
          assert_equal sub.concurrency, msg.times_seen, "#{sub.client}: Concurrent subscribers didn't all receive message #{i}."
          i+=1
        end
      else
        verify pub, sub
      end
    end
    subs.each &:terminate
  end
  #def test_expired_messages_with_subscribers
  #  chan = short_id
  #  pub, sub = pubsub 1, pub: "/pub/2_sec_message_timeout/", sub: "/sub/intervalpoll/", client: :intervalpoll, timeout: 9000, channel: short_id
  #  sub.on_failure do |err|
  #    puts "retry?!!"
  #    true
  #  end
  #  sub.run
  #  pub.post ["foo", "bar"]
  #  
  #  sleep 5
  #  
  #  pub.post ["yeah", "what", "the"]
  #  sub.wait
  #end
  
  
  class CallbackStatus
    attr_accessor :subbed, :unsubbed, :authed, :need_auth, :client_type
    def initialize(client_type, opt)
      @client_type = client_type
      opt ||= {}
      @need_auth = true if opt[:auth]
    end
    def clear
      @subbed = false
      @unsubbed = false
      @authed = false
    end
  end
  def verify_callback_status(cbs)
    assert cbs.authed, "auth callback missing" if cbs.need_auth
    if cbs.client_type == :longpoll || cbs.client_type == :intervalpoll
      assert !cbs.subbed, "sub callback should not have been fired"
      assert !cbs.unsubbed, "unsub callback should not have been fired"
    else
      assert cbs.subbed, "sub callback missing"
      assert cbs.unsubbed, "unsub callback missing"
    end
    true
  end
  
  def start_authserver(opt={}, &block)
    auth = AuthServer.new opt, &block
    auth.run
    while true
      resp = Typhoeus.get("http://127.0.0.1:8053/", followlocation: true)
      break unless resp.return_code == :couldnt_connect
      sleep 0.20
    end
    return auth
  end
  
  [:longpoll, :multipart, :chunked, :eventsource, :websocket].each do |client_type|
    [true, nil].each do |with_auth|
      define_method "test_#{with_auth and "auth_"}subscribe_callbacks_#{client_type}" do
        
        Celluloid.logger = nil
        
        cbs = CallbackStatus.new(client_type, auth: with_auth)
        
        auth = start_authserver quiet: true do |env|
          if env["PATH_INFO"] == "/sub"
            #print "subbed"
            cbs.subbed = true
          elsif env["PATH_INFO"] == "/unsub"
            #print "unsubbed"
            cbs.unsubbed = true
          elsif env["PATH_INFO"] == "/auth" 
            cbs.authed = true
          end
        end
        
        begin
          chan = short_id
          
          #puts client_type
          
          pub = Publisher.new url("pub/#{chan}")
          cbs.clear
          
          sub = Subscriber.new(url("/sub/withcb#{with_auth && "auth"}/#{chan}"), 1, quit_message: 'FIN', retry_delay: 1, timeout: 500, client: client_type)
          sub.on_failure { false }
          
          #client-side abort
          sub.run
          #sub.wait :ready
          sleep 0.5
          sub.stop
          sleep 1
          
          verify_callback_status cbs
          
          sub.reset
          cbs.clear
          sub.run
          #sub.wait :ready
          sleep 0.5
          pub.delete
          sub.wait
          sleep 0.5
          sub.reset
          
          verify_callback_status cbs
          cbs.clear
          
          pub.messages.clear
          sub.messages.clear
          
          sub.run
          sleep 0.5
          pub.post ["hi", "ho", "hum"]
          
          pub.post "FIN"
          sleep 0.5
          sub.wait
          
          verify pub, sub
          sub.terminate
          
          verify_callback_status cbs
          
        rescue SystemCallError => e
          assert false, "Error: #{e}"
        ensure
          auth.stop
        end
      end
    end
  end
  
  def test_auth
    chan = short_id
    
    subs = [:longpoll, :multipart, :chunked, :eventsource, :websocket ]
    
    subs.each do |t|
      sub = Subscriber.new(url("sub/auth_fail/#{chan}"), 1, client: t)
      sub.on_failure { false }
      sub.run
      sub.wait
      assert sub.errors?
      assert sub.match_errors(/502/), "#{t} subscriber expected 502 error"
      sub.terminate
    end
    
    
    auth = AuthServer.new quiet: true
    auth.run
    sleep 0.5
    
    while true
      resp = Typhoeus.get("http://127.0.0.1:8053/", followlocation: true)
      break unless resp.return_code == :couldnt_connect
      sleep 0.20
    end
    
    begin 
      subs.each do |t|
        sub = Subscriber.new(url("sub/auth_fail/#{chan}"), 1, client: t)
        sub.on_failure { false }
        sub.run
        sub.wait
        assert sub.errors?
        assert sub.match_errors(/403/)
        sub.terminate
      end
      
      subs.each do |t|
        sub = Subscriber.new(url("sub/auth_fail_weird/#{chan}"), 1, client: t)
        sub.on_failure do |err, bundle|
          assert_match "too-ripe", bundle.headers["X-Banana"]
          assert_match "text/x-beef", bundle.headers["Content-Type"]
          assert_match "f38697175091d1667f5187c016cba46d092baf6a", Digest::SHA1.hexdigest(bundle.body_buf)
          false
        end
        sub.run
        sub.wait
        assert sub.errors?
        assert sub.match_errors(/406/)
        sub.terminate
      end
      
      subs.each do |t|
        sub = Subscriber.new(url("sub/auth_fail_sleepy/#{chan}"), 1, client: t)
        sub.on_failure { false }
        sub.run
        sub.wait
        assert sub.errors?
        assert sub.match_errors(/504/)
        sub.terminate
      end
      
      pub = Publisher.new url("pub/#{chan}")
      
      pub.post [ "wut", "waht", "FIN" ]
      
      subs.each do |t|
        sub = Subscriber.new(url("sub/auth/#{chan}"), 1, client: t, quit_message: 'FIN')
        sub.on_failure { false }
        sub.run
        sub.wait
        verify pub, sub
        sub.terminate
      end
    ensure
      auth.stop
    end
  end
  
  
  def test_x_accel_redirect
    
    auth = start_authserver quiet: true
    
    subs = [ :longpoll, :chunked, :eventsource, :websocket, :multipart ]
    
    subs.each do |t|
      chan = short_id
      pub = Publisher.new url("upstream_redirect/pub/#{chan}")
      sub = Subscriber.new(url("upstream_redirect/sub/#{chan}"), 1, client: t, quit_message: 'FIN')
      sub.run
      sleep 0.5
      pub.post [ "wut", "waht", "FIN" ]
      sub.wait
      verify pub, sub
      sub.terminate
    end
    
    auth.stop
  end
  
  def test_access_control
    
    ver= proc do |bundle| 
      assert_equal "example.com", bundle.headers["Access-Control-Allow-Origin"] 
    end
    generic_test_access_control(origin: "example.com", verify_sub_response: ver) do |pub, sub|
      verify pub, sub
    end
    
    ver= proc do |bundle| 
      assert_equal "http://foo.bar", bundle.headers["Access-Control-Allow-Origin"] 
      %w( Last-Modified Etag ).each {|v| assert_header_includes bundle, "Access-Control-Expose-Headers", v}
    end
    generic_test_access_control(origin: "http://foo.bar", verify_sub_response: ver, sub_url: "sub/from_foo.bar/") do |pub, sub|
      verify pub, sub
    end
    
    #test in if block
    origin_host=""
    ver= proc do |bundle| 
      assert_equal origin_host, bundle.headers["Access-Control-Allow-Origin"]
      %w( Last-Modified Etag ).each {|v| assert_header_includes bundle, "Access-Control-Expose-Headers", v}
    end
    origin_host="http://foo.bar"
    generic_test_access_control(origin: origin_host, verify_sub_response: ver, param: {foo: "foobar"}, sub_url: "/sub/access_control_in_if_block/") do |pub, sub|
      verify pub, sub
    end
    origin_host="http://bana.na"
    generic_test_access_control(origin: origin_host, verify_sub_response: ver, param: {foo: "banana"}, sub_url: "/sub/access_control_in_if_block/") do |pub, sub|
      verify pub, sub
    end
    origin_host="http://localhost"
    generic_test_access_control(origin: origin_host, verify_sub_response: ver, param: {foo: "localhost"}, sub_url: "/sub/access_control_in_if_block/") do |pub, sub|
      verify pub, sub
    end
    
    origin_host="http://localhost"
    on_fail = proc { false }
    generic_test_access_control(origin: origin_host, verify_sub_response: ver, on_failure: on_fail, sub_url: "/sub/access_control_in_if_block/") do |pub, sub|
      sub.errors.each do |err|
        assert_match /code 403/, err
      end
    end
    
    #test forbidding stuff
    pub, sub = pubsub 1, extra_headers: { "Origin" => "http://forbidden.com" }, pub: "pub/from_foo.bar/", sub: "sub/from_foo.bar/", timeout: 1
    
    pub.extra_headers={ "Origin" => "http://foo.bar" }
    pub.post "yeah"
    
    assert_match /20[12]/, pub.response_code.to_s
    pub.extra_headers={ "Origin" => "http://forbidden.com" }
    post_failed = false
    begin 
      pub.post "yeah"
    rescue Exception => e
      post_failed = true
      assert_match /request failed:\s+403/, e.message
    end
    assert post_failed
    
    sub.on_failure { false }
    
    sub.run
    sub.wait
    
    sub.errors.each do |err|
      assert_match /code 403/, err
    end
    sub.terminate
  end
  
  def test_gzip
    #bug: turning on gzip cleared the response etag
    pub, sub = pubsub 1, sub: "/sub/gzip/", gzip: true, retry_delay: 0.3
    sub.run
    sleep 0.1
    pub.post ["2", "123456789A", "alsdjklsdhflsajkfhl", "boq"]
    sleep 1
    pub.post "foobar"
    msg = ""
    200.times { msg << SecureRandom.hex }
    pub.post msg
    pub.post "FIN"
    sub.wait
    verify pub, sub
    sub.terminate
  end
  
  def test_issue_212 #https://github.com/slact/nchan/issues/212
    chan1 = short_id
    chan2 = short_id
    sub = Subscriber.new url("/sub/multi/#{chan1}/#{chan2}"), 1, quit_message: 'FIN', client: :eventsource, timeout: 3
    sub.on_failure { false }
    pub = Publisher.new url("/pub/#{chan1}")
    pub_nobuf = Publisher.new url("/pub/nobuffer/#{chan2}")
    sub.run
    sub.wait :ready

    pub.post %w(yes what this and also)
    sleep 1.1
    pub_nobuf.post "WHAT?!"
    pub.messages << pub_nobuf.messages.first
    pub.post %W(foo bar baz bzzzt FIN)

    sub.wait
    
    verify pub, sub
    sub.terminate
  end
  
  def test_changing_buffer_length
    chan = short_id
    sub = Subscriber.new url("sub/broadcast/#{chan}"), 30, quit_message: 'FIN'
    pub_delta = Publisher.new url("/pub/#{chan}")
    pub_snapshot = Publisher.new url("/pub_1message/#{chan}")
    
    pub_delta.post %W(foo bar baz bzzzt FIN)
    sub.run
    sub.wait
    verify pub_delta, sub
    sub.reset
    
    pub_snapshot.post %W(blah anotherblah)
    pub_snapshot.messages.clear
    pub_snapshot.post "this is the real thing right here"
    
    pub_delta.messages.clear
    pub_delta.messages << pub_snapshot.messages.first
    pub_delta.post %W(d1 d2 d3 and_other_deltas FIN)
    sub.run
    sub.wait
    
    verify pub_delta, sub
    sub.terminate
  end
  
  def test_websocket_binary_frame
    pub, sub=pubsub 1, client: :websocket
    n=0
    msgs = [
      ["hey there",               nil],
      ["this is binary",          "application/octet-stream"],
      ["what",                    "text/x-whatever"],
      [((0..255).map &:chr).join,  "application/octet-stream"],
      ["FIN",                     nil]
    ]
    
    sub.on_message do |msg, bundle|
      if msgs[n][1]=="application/octet-stream" then #should be binary
        assert(bundle.last_message_frame_type==:binary, "websoket frame should be binary")
      else
        assert(bundle.last_message_frame_type==:text, "websoket frame should be text")
      end
      n+= 1
    end
    
    sub.run
    msgs.each do |msg|
      msg[0].force_encoding("ascii-8bit") if msg[1]=="application/octet-stream"
      pub.post msg[0], msg[1]
    end
    sub.wait
    verify pub, sub
    sub.terminate
  end
  
  def test_websocket_subprotocol
    test_broadcast 1, {client: :websocket}, {must_have_message_ids: false, content_type: "x/foo", must_have_content_type: false}
    test_broadcast 10, {client: :websocket, subprotocol: "ws+meta.nchan"}, {must_have_message_ids: true, content_type: "x/foo", must_have_content_type: true}
  end
  
  def test_websocket_permessage_deflate_subscribe
    chan = short_id
    
    sub = Subscriber.new(url("/sub/broadcast/#{chan}"), 1, quit_message: 'FIN', client: :websocket, permessage_deflate: true)
    sub.on_message do |msg, bundle|
      if msg.message[0] == "C"
        assert bundle.ws.last_message.rsv1, "expected RSV1 to be 1, was 0"
      elsif msg.message[0] == "R"
        assert bundle.ws.last_message.rsv1 == false, "expected RSV1 to be 0, was 1"
      end
    end
    
    sub_subprotocol = Subscriber.new(url("/sub/broadcast/#{chan}"), 20, quit_message: 'FIN', client: :websocket, permessage_deflate: true, subprotocol: "ws+meta.nchan")
    sub_subprotocol.on_message do |msg, bundle|
      if msg.message[0] == "C"
        assert bundle.ws.last_message.rsv1, "expected RSV1 to be 1, was 0"
      elsif msg.message[0] == "R"
        assert bundle.ws.last_message.rsv1 == false, "expected RSV1 to be 0, was 1"
      end
    end
    
    pub = Publisher.new url("/pub/#{chan}")
    
    rurl = url("/pub/#{chan}")
    curl = url("/pub/deflate/#{chan}")
    
    sub.run
    sub_subprotocol.run
    sub.wait :ready
    sub_subprotocol.wait :ready
    pub.url = rurl
    pub.post ["R:HEY YTHERE", "R:this is simple", "R:banana"]
    
    pub.url = curl
    pub.post ["C:hello again", "C:wut?", "C:#{'q'*1024}", "C:#{'c'*30000}"]
    pub.post "C:#{Random.new.bytes 10000}", "application/octet-stream"
    pub.post "C:#{Random.new.bytes 20000}", "application/octet-stream"
    pub.post "C:#{Random.new.bytes 60000}", "application/octet-stream"
    
    pub.url = rurl
    pub.post "R:#{Random.new.bytes 60000}", "application/octet-stream"
    pub.post "FIN"
    
    sub.wait
    sub_subprotocol.wait
    verify pub, sub
    verify pub, sub_subprotocol
    
    sub.terminate
    sub_subprotocol.terminate
  end
  
  def test_websocket_permessage_deflate_publish
    
    [true, false].each do |deflated|
      chan = short_id
      sub = Subscriber.new(url("/sub/broadcast/#{chan}"), 1, quit_message: 'FIN', client: :websocket, permessage_deflate: true)
      sub.on_message do |msg, bundle|
        if deflated
          assert bundle.ws.last_message.rsv1, "expected RSV1 to be 1, was 0"
        else
          assert bundle.ws.last_message.rsv1 == false, "expected RSV1 to be 0, was 1"
        end
      end
      
      pub = Publisher.new url("/pub/#{deflated ? "deflate/" : ""}#{chan}"), ws: true, permessage_deflate: true
      pub_client = pub.ws.client
      pub_bundle = pub_client.ws.first.first
      
      assert pub_bundle.ws.headers["sec-websocket-extensions"].match(/permessage-deflate/)
      
      pub.post "here is a message"
      pub.post "here is another"
      sub.run
      pub.post "q"*10000
      pub.post "q"*40000
      pub.post "C:#{Random.new.bytes 10000}", "application/octet-stream"
      pub.post "C:#{Random.new.bytes 40000}", "application/octet-stream"
      pub.post "FIN"
      
      sub.wait
      
      verify pub, sub
      sub.terminate
      pub.terminate
    end
    
  end
  
  def check_websocket_handshake(url, headers, expected_response_code=101, expected_response_body_match=nil)
    req=Typhoeus::Request.new(url, headers: headers, forbid_reuse: true)
    req.run
    binding.pry if expected_response_code != req.response.response_code
    assert_equal expected_response_code, req.response.response_code
    assert req.response.body.match(expected_response_body_match) if expected_response_body_match
    req.response
  end
  
  def test_websocket_handshakes
    url = url("/sub/broadcast/#{short_id}")
    ws_guid="258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    
    headers = {"Connection":"Upgrade", "Upgrade":"Websocket"}
    
    check_websocket_handshake(url, headers, 400, /No Sec-Websocket-Version/)
    
    headers["Sec-Websocket-Version"]="banana"
    check_websocket_handshake(url, headers, 400, /Unsupported websocket protocol version/)
    
    headers["Sec-Websocket-Version"]="14"
    check_websocket_handshake(url, headers, 400, /Unsupported websocket protocol version/)
    
    headers["Sec-Websocket-Version"]="13"
    check_websocket_handshake(url, headers, 400, /No Sec-Websocket-Key/)
    
    headers["Sec-Websocket-Key"]="q"*120
    resp = check_websocket_handshake(url, headers)
    assert_equal Digest::SHA1.base64digest("#{headers["Sec-Websocket-Key"]}#{ws_guid}"), resp.headers["Sec-Websocket-Accept"]
    
    headers["Sec-Websocket-Key"]=" space check       "
    resp = check_websocket_handshake(url, headers)
    assert_equal Digest::SHA1.base64digest("#{headers["Sec-Websocket-Key"].strip}#{ws_guid}"), resp.headers["Sec-Websocket-Accept"]
    
    headers["Sec-Websocket-Extensions"]="permessage-deflate; client_max_window_bits=6"
    check_websocket_handshake(url, headers, 400, /client_max_window_bits.*out of range/)
    
    headers["Sec-Websocket-Extensions"]="permessage-deflate; server_max_window_bits=2000"
    check_websocket_handshake(url, headers, 400, /server_max_window_bits.*out of range/)
    
    headers["Sec-Websocket-Extensions"]="x-webkit-deflate-frame; max_window_bits=6"
    check_websocket_handshake(url, headers, 400, /max_window_bits.*out of range/)
    
    headers["Sec-Websocket-Extensions"]="x-webkit-deflate-frame; max_window_bits=10"
    check_websocket_handshake(url, headers)    
  end

end


