require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"

class Place::Meet < PlaceOS::Driver
  generic_name :System
  descriptive_name "Meeting room logic"
  description <<-DESC
    Room level state and behaviours.

    This driver provides a high-level API for interaction with devices, systems \
    and integrations found within common workplace collaboration spaces.
    DESC

  default_settings({
    help: {
      "help-id" => {
        "title"   => "Video Conferencing",
        "content" => "markdown"
      }
    },
    tabs: [
      {
        name: "VC",
        icon: "conference",
        inputs: ["VidConf_1"],
        help: "help-id",
        controls: "vidconf-controls",
        merge_on_join: false
      }
    ],

    # if we want to display the selected tab on displays meant only for the presenter
    preview_outputs: ["Display_2"],

    # only required in joining rooms
    local_outputs: ["Display_1"],
  })
end

require "./router"

alias Help = Hash(String, NamedTuple(
  title: String,
  content: String
))

class Tab
  include JSON::Serializable

  def initialize(@icon, @name, @inputs, @help = nil, @controls = nil, @merge_on_join = nil)
  end

  getter icon : String
  getter name : String
  getter inputs : Array(String)

  getter help : String?
  getter controls : String?
  getter merge_on_join : Bool?

  def merge(tab : Tab) : Tab
    input = inputs.dup.concat(tab.inputs).uniq!
    Tab.new(@icon, @name, input, @help, @controls, @merge_on_join)
  end

  def merge!(tab : Tab) : Tab
    @inputs.concat(tab.inputs).uniq!
    self
  end
end

class Place::Meet < PlaceOS::Driver
  include Interface::Muteable
  include Interface::Powerable
  include Router::Core

  def on_load
    on_update
  end

  @tabs : Array(Tab) = [] of Tab
  @local_tabs : Array(Tab) = [] of Tab
  @local_help : Help = Help.new
  @local_outputs : Array(String) = [] of String
  @preview_outputs : Array(String) = [] of String

  def on_update
    self[:name] = system.display_name || system.name
    self[:local_help] = @local_help = setting?(Help, :help) || Help.new
    self[:local_tabs] = @local_tabs = setting?(Array(Tab), :tabs) || [] of Tab
    self[:local_outputs] = @local_outputs = setting?(Array(String), :local_outputs) || [] of String
    self[:preview_outputs] = @preview_outputs = setting?(Array(String), :preview_outputs) || [] of String

    load_siggraph
    update_available_tabs
    update_available_help
    update_available_outputs
  end

  protected def on_siggraph_loaded(inputs, outputs)
    outputs.each &.watch { |node| on_output_change node }
  end

  protected def on_output_change(output)
    case output.source
    when Router::SignalGraph::Mute, nil
      # nothing to do here
    else
      output.proxy.power true
    end
  end

  protected def all_outputs
    status(Array(String), :outputs)
  end

  protected def update_available_help
    help = @local_help.dup
    # TODO:: merge in joined room help
    self[:help] = help
  end

  protected def update_available_tabs
    tabs = @local_tabs.dup
    # TODO:: merge in joined room tabs
    self[:tabs] = @tabs = tabs
  end

  protected def update_available_outputs
    available_outputs = @local_outputs.dup
    preview_outputs = @preview_outputs.dup

    # TODO:: merge in joined room settings

    if available_outputs.empty?
      if preview_outputs.empty?
        self[:available_outputs] = nil
      else
        self[:available_outputs] = all_outputs - preview_outputs
      end
    else
      self[:available_outputs] = available_outputs
    end
  end

  # Sets the overall room power state.
  def power(state : Bool)
    return if state == self[:active]?
    logger.debug { "Powering #{state ? "up" : "down"}" }
    self[:active] = state

    if state
      # no action - devices power on when signal is routed
    else
      system.implementing(Interface::Powerable).power false
    end
  end

  # Set the volume of a signal node within the system.
  def volume(level : Int32, input_or_output : String)
    logger.info { "setting volume on #{input_or_output} to #{level}" }
    node = signal_node input_or_output
    node.proxy.volume level
    node["volume"] = level
  end

  # Sets the mute state on a signal node within the system.
  def mute(state : Bool = true, input_or_output : Int32 | String = 0, layer : MuteLayer = MuteLayer::AudioVideo)
    # Int32's accepted for Muteable interface compatibility
    unless input_or_output.is_a? String
      raise ArgumentError.new("invalid input or output reference: #{input_or_output}")
    end

    logger.debug { "#{state ? "muting" : "unmuting"} #{input_or_output} #{layer}" }

    node = signal_node input_or_output

    case layer
    in .audio?
      node.proxy.audio_mute(state).get
      node["mute"] = state
    in .video?
      node.proxy.video_mute(state).get
      node["video_mute"] = state
    in .audio_video?
      node.proxy.mute(state).get
      node["mute"] = state
      node["video_mute"] = state
    end
  end

  def selected_input(name : String) : Nil
    self[:selected_input] = name
    self[:selected_tab] = @tabs.find(@tabs.first, &.inputs.includes?(name)).name
    @preview_outputs.each { |output| route(name, output) }
  end
end
