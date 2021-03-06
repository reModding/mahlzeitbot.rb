#!/usr/bin/env ruby

require 'date'
require 'socket'
require 'yaml'

class MyBot
  def initialize(server, port, channel, nick, cache, wasgibts)
    @channel = channel
    # Hard cut of the nick length if it exceeds 9 characters:
    @nick = nick[0, 9]
    @cache_file = cache
    @wasgibts = wasgibts

    @lastvote = Date.today.yday

    @cache = YAML.load_file(@cache_file)
    @socket = TCPSocket.open(server, port)

    say "NICK #{@nick}"
    say "USER #{@nick} 8 * :#{@nick}"
    say "JOIN #{@channel}"
  end

  def say(msg)
    puts msg
    @socket.puts msg
  end

  def say_to_chan(msg)
    say "PRIVMSG #{@channel} :#{msg}"
  end

  def say_to_nick(nick, msg)
    say "PRIVMSG #{nick} :#{msg}"
  end

  def write_cache
    File.open(@cache_file, "w") do |f|
      f.write @cache.to_yaml
    end
  end

  def check
    until @socket.eof? do
      msg = @socket.gets
      puts msg

      if msg.match(/004/)
        break
      elsif msg.match(/433/)
        abort "Nick is already in use."
      end
    end
  end
  
  def run
    check

    who_list = []
    nick_list = []
    forcecmd = nil

    until @socket.eof? do
      msg = @socket.gets
      puts msg

      case msg
      when /^PING :(.*)$/
        say "PONG #{$~[1]}"
        next

      when /^:(.*)!(.*) PRIVMSG (.*) :(.*)$/
        nick = $~[1]
        login = $~[2]
	rcpt = $~[3]
        content = $~[4]

        # Ignore my own messages:
        if nick == @nick
          next
        end

	# Message to me?
	if rcpt == @nick
	  say_to_nick nick, "Bitte antworte mir in #{@channel}."
	  next
	end

	case content
        when /^\+help/
          help

        when /^\+([0-9]*) (.*)/
          votes = $~[1].to_i
          voted_loc = $~[2].chop

          if votes > 1
            say_to_chan "Ich habe das Gefuehl, #{nick} ist heute besonders hungrig. Trotzdem hat jeder nur eine Stimme pro Ort."
          elsif votes == 1
            check_daily_reset
            add_vote voted_loc, nick, login
          end

        when /^-1 (.*)/
          voted_loc = $~[1].chop

          del_vote voted_loc, nick, login

        when /^\+orte/
          orte

        when /^\+(stand|wiestehts)/
          check_daily_reset
          stand

        when /^\+(wasgibts|wasgibtsheute)/
          wasgibts nick

        when /^\+werfehlt/
          check_daily_reset
	  forcecmd = :werfehlt
          say "WHO #{@channel}"

        when /^\+(wergeht|wergehtzu)/
          loc = $~[1]

          check_daily_reset
	  forcecmd = :wergeht
          say "WHO #{@channel}"

        when /^\+add ([a-zA-Z]*)/
          loc = $~[1]

          check_daily_reset
          add_loc loc

        when /^\+del ([a-zA-Z]*)/
          loc = $~[1]

          check_daily_reset
          del_loc loc

        when /^\+reset/
          reset
	end

      when /^:(.*) 352 (.*) #{@channel} (.*)$/
        who = $~[3].chop.split(" ")

        if who[3] != @nick
          who_list << "#{who[0]}@#{who[1]}"
          nick_list << who[3]
        end

      when /^:(.*) 315 (.*) #{@channel} :(.*)$/
        case forcecmd
	  when :werfehlt
            werfehlt who_list, nick_list
	  when :wergeht
	    wergeht who_list, nick_list, nick, login
	end

        who_list = []
        nick_list = []
      end
    end
  end

  def help
    say_to_chan "+orte     - gibt eine Liste aller Orte aus, die ich kenne."
    say_to_chan "+1 ORT    - stimmt fuer den Ort."
    say_to_chan "-1 ORT    - nimmt seine Stimme zurueck."
    say_to_chan "+stand    - gibt den aktuellen Punktestand aus."
    say_to_chan "+wasgibts - schickt den aktuellen Intra-Link."
    say_to_chan "+werfehlt - zeigt alle an, die noch nicht gevotet haben."
    say_to_chan "+wergeht  - zeigt alle an, die zu diesem Ort gehen."
    say_to_chan "+add ORT  - fuegt einen Ort hinzu."
#   say_to_chan "+del ORT  - entfernt einen Ort."
    say_to_chan "+reset    - setzt alle Votes zurueck."
  end

  def count_votes(loc)
    vote_count = -1

    @cache["locations"].each do |k, v|
      if k.downcase == loc.downcase
        vote_count = @cache["locations"][k].split(" ").length
      end
    end

    return vote_count
  end

  def add_vote(voted_loc, nick, login)
    res = 0

    @cache["locations"].each do |k, v|
      if k.downcase == voted_loc.downcase
        if @cache["locations"][k].nil?
          @cache["locations"][k] = "#{login}"
          write_cache
          res = 1
        elsif @cache["locations"][k].split(" ").include?(login)
          res = 2
        else
          logins_voted = @cache["locations"][k].split(" ")
          logins_voted << "#{login}"
          @cache["locations"][k] = logins_voted.join(" ")
          write_cache
          res = 1
        end

        break
      end
    end

    case res
      when 0
        say_to_chan "#{voted_loc} kenne ich nicht."
      when 1
        say_to_chan "#{nick} stimmt fuer #{voted_loc}. Neuer Punktestand: #{count_votes voted_loc}"
      when 2
        say_to_chan "Sorry, aber Du (#{login}) hast bereits fuer #{voted_loc} gestimmt."
    end
  end

  def del_vote(voted_loc, nick, login)
    res = 0

    @cache["locations"].each do |k, v|
      if k.downcase == voted_loc.downcase
        if @cache["locations"][k].nil?
          res = 2
        else
          logins_voted = @cache["locations"][k].split(" ")
      
          if logins_voted.include?(login)
            logins_voted.delete login
            @cache["locations"][k] = logins_voted.join(" ")
            write_cache
            res = 1
          else
            res = 2
          end
        end

        break
      end
    end

    case res
      when 0
        say_to_chan "#{voted_loc} kenne ich nicht."
      when 1
        say_to_chan "#{nick} hat seine Stimme fuer #{voted_loc} zurueckgenommen. Neuer Punktestand: #{count_votes voted_loc}"
      when 2
        say_to_chan "Sorry, aber Du (#{login}) hast nicht fuer #{voted_loc} gestimmt."
    end
  end

  def orte
    loc_keys = []

    @cache["locations"].each do |k, v|
      loc_keys << k
    end

    say_to_chan(loc_keys.sort.join(", "))
  end

  def stand
    loc_stand = []

    @cache["locations"].each do |k, v|
      if !v.nil? && !v.empty?
        loc_stand << "#{count_votes(k)}x #{k}"
      end
    end

    if loc_stand.length == 0
      say_to_chan "Heute hat noch niemand eine Stimme abgegeben."
    else
      say_to_chan loc_stand.sort_by(&:to_i).reverse.join(", ")
    end
  end

  def add_loc(loc)
    if @cache["locations"].map { |k, v| k.downcase }.include?(loc.downcase)
      say_to_chan "#{loc} kenne ich bereits."
    else
      @cache["locations"]["#{loc}"] = ""
      write_cache
      say_to_chan "#{loc} hinzugefuegt."
    end
  end

  def del_loc(loc)
    if @cache["locations"].map { |k, v| k.downcase }.include?(loc.downcase)
      @cache["locations"].delete "#{loc}"
      write_cache
      say_to_chan "#{loc} geloescht."
    else
      say_to_chan "#{loc} kenne ich nicht."
    end
  end

  def wasgibts(nick)
    say_to_chan("#{nick}, schau bitte hier: #{@wasgibts}")
  end

  def werfehlt(who_list, nick_list)
    names_voted = []

    @cache["locations"].each do |k, v|
      if !v.nil? && !v.empty?
        v.split(" ").each do |n|
          names_voted << n
        end
      end
    end

    names_voted.uniq!

    names_voted.each do |n|
      who_list_i = who_list.index(n)
      who_list.delete_at(who_list_i)
      nick_list.delete_at(who_list_i)
    end

    if nick_list.length == 0
      say_to_chan "Es haben schon alle im Channel abgestimmt."
    else
      say_to_chan "Bitte voten: #{nick_list.join(", ")}"
    end
  end

  def wergeht(who_list, nick_list, nick, login)
    locations_voted = []

    @cache["locations"].each do |k, v|
      if !v.nil? && !v.empty?
        nicks_voted = []

        v.split(" ").each do |n|
	  nicks_voted << nick_list[who_list.index(n)]
        end
        
	locations_voted << "#{count_votes(k)}x #{k}: #{nicks_voted.join(", ")}"
      end
    end

    if locations_voted.length == 0
      say_to_chan "Es hat noch keiner abgestimmt."
    else
      say_to_chan "#{nick}: Um Highlight-Spam zu verhindern, habe ich Dir diese Nachricht im Query geschickt."
      say_to_nick nick, "#{locations_voted.sort_by(&:to_i).reverse.join(" / ")}"
    end
  end

  def reset
    @cache["locations"].each do |k, v|
      @cache["locations"][k] = ""
    end

    write_cache
    say_to_chan "Alle Votes stehen wieder auf 0."
  end

  def check_daily_reset
    if @lastvote != Date.today.yday
      @lastvote = Date.today.yday
      say_to_chan "Neuer Tag, neues Glueck. Was es heute gibt, steht hier: #{@wasgibts}"
      reset
    end
  end

  def quit
    say "PART #{@channel}"
    say "QUIT"
  end
end


config = YAML.load_file(ARGV[1])
bot = MyBot.new(config["irc"]["server"], config["irc"]["port"], config["irc"]["channel"], config["irc"]["nick"], config["cache"], config["wasgibts"])

trap("INT") do
  bot.quit
end

bot.run
