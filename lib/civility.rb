require 'thor'

class Civility < Thor
  VERSION = '5'
  FILE_PREFIX = 'civility'
  FILE_EXT = 'Civ5Save'
  CONFIG_FILE = '.civility.yml'
  OS = lambda do
    # From http://stackoverflow.com/a/171011/1621312
    case RUBY_PLATFORM
    when /cygwin|mswin|mingw|bccwin|wince|emx/
      :windows
    when /darwin/
      :mac
    else
      fail "Unknown Platform #{RUBY_PLATFORM}"
    end
  end.call

  PLATFORM_DIRS = {
    windows: "/Documents/my games/Sid Meier's Civilization 5",
    mac: "/Documents/Aspyr/Sid\ Meier\'s\ Civilization\ 5",
    linux: nil
  }.freeze
  SAVE_DIRECTORY = "#{PLATFORM_DIRS[OS]}/Saves/hotseat/"

  CIV_APPID = 8930
  RUN_URI = "steam://run/#{CIV_APPID}"
  RUN_CMDS = {
    windows: 'start',
    mac: 'open',
    linux: nil
  }.freeze
  RUN_CMD = "#{RUN_CMDS[OS]} #{RUN_URI}"

  def initialize(*args)
    @config = Civility::Config.new(path: config_path)
    @gmr = Civility::GMR.new(auth_key, user_id) if auth_key
    super(*args)
  end

  desc 'auth', 'Save auth key'
  option aliases: :a
  def auth(auth_key = nil)
    if auth_key.nil?
      auth_url = Civility::GMR.auth_url
      puts "Grab your Authentication Key from #{auth_url}"
      system('open', auth_url)
    else
      @gmr = Civility::GMR.new(auth_key)
      config.set(version: VERSION, auth: auth_key, user: user)
      puts "Hello, #{user['PersonaName']}, your auth is all configured!"
    end
  end

  desc 'games', 'List your current games'
  option aliases: :g
  def games
    return missing_auth_error unless auth_key
    output_games sync_games
  end

  desc 'play', 'Download a game to play'
  option aliases: :p
  def play(*name)
    name = name.join(' ')
    return missing_auth_error unless auth_key
    game = game_by_name(name)
    return missing_game_error(name) unless game
    path = save_path(game)
    data = @gmr.download(game['GameId'])
    save_file(path, data)
    puts "Saved #{game['Name']} to #{path}"
    run_civilization
    sync_games
  end

  desc 'complete', 'Upload a completed turn'
  option aliases: :c
  def complete(*name)
    name = name.join(' ')
    return missing_auth_error unless auth_key
    game = game_by_name(name)
    return missing_game_error(name) unless game
    path = save_path(game)
    response = @gmr.upload(game['CurrentTurn']['TurnId'], File.read(path))
    case response['ResultType']
    when 0
      puts "UnexpectedError: #{response}"
    when 1
      puts "You earned #{response['PointsEarned']} points completing #{game['Name']} from #{path}"
      notify_slack(game) if config.get(:slack)
    when 2
      puts "It's not your turn"
    when 3
      puts 'You already submitted your turn'
    else
      puts 'UnexpectedError'
    end
  end

  desc 'slack', 'Enable slack integration'
  def slack(status, bot_token = nil, channel_name = nil, next_player_name = nil, game_name = nil)
    if status == 'on'
      if [bot_token, channel_name, next_player_name, game_name].any?(&:nil?)
        puts 'Bot token, channel name, next player name, and game name are required'
        puts '$ civility slack on xoxb-123xyz awecome_channel sam awesome civ 5 game'
      else
        game = game_by_name(game_name)
        return missing_game_error(name) unless game
        slack_config = config.get(:slack) || {}
        slack_config.merge!(
          game['GameId'] => {
            channel_name: channel_name,
            bot_token: bot_token,
            next_player_name: next_player_name
          }
        )
        config.set(slack: slack_config)
        puts "Slack integration enabled for #{game_name}"
      end
    else
      config.delete(:slack)
      puts 'Slack integration disabled'
    end
  end

  private

  attr_reader :config

  def notify_slack(game)
    slack_config = config.get(:slack)[game['GameId']]
    return puts 'Slack not configured for game' unless slack_config
    slack = Civility::Ext::Slack.new(slack_config[:bot_token])
    message = "@#{slack_config[:next_player_name]}'s turn!"
    code, body = slack.post_message(slack_config[:channel_name], message, 'Shelly')
    puts "Error updating Slack: #{body}" unless code == 200
  end

  def sync_games
    games = @gmr.games
    config.set(games: games)
    games
  end

  def save_path(game)
    "#{Dir.home}#{SAVE_DIRECTORY}#{FILE_PREFIX}-#{normalize(game['Name'])}-#{game['GameId']}.#{FILE_EXT}"
  end

  def auth_key
    config.get(:auth)
  end

  def user_id
    config.get(:user)['SteamID']
  end

  def games_list
    config.get(:games)
  end

  def output_games(games)
    games.each do |game|
      turn = (user_id == game['CurrentTurn']['UserId'] ? " and it's your turn" : '')
      puts "#{game['Name']} with #{game['Players'].size} other players#{turn}"
    end
    puts "\nIf your games are missing, try again"
  end

  def game_by_name(name)
    name = normalize(name)
    games_list.find { |game| normalize(game['Name']) == name }
  end

  def user
    @gmr.user
  end

  def normalize(name)
    name.downcase.strip.gsub(/[^\w]/, '')
  end

  def save_file(path, data)
    open(path, 'wb') do |file|
      file.write(data)
    end
  end

  def missing_game_error(name)
    puts "Unable to find the game #{name}"
  end

  def missing_auth_error
    puts 'Please run `civility auth` first'
  end

  def run_civilization
    `#{RUN_CMD}`
  end

  def config_path
    "#{Dir.home}/#{CONFIG_FILE}"
  end
end

require 'civility/config'
require 'civility/gmr'
require 'civility/ext'
