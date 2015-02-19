#!/usr/bin/env ruby
# encoding: UTF-8
#
# Copyright (C) 2012-2014 Guillaume Laville <laville.guillaume@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>
   
# REQUIREMENTS
#
# - ruby (of course)
# - graphviz (for output conversion)
# - ruby-graphviz gem (gem install ruby-graphviz)
#
# USAGE
#
#   topology.rb -f png <"iblinkinfo --line" output file> OR
#   iblinkinfo --line | topology.rb -f png

require 'optparse'
require 'graphviz'

# DEFAULT SETTINGS

SETTINGS = {
  :use_color     => true,       # Enable colored output
  :all_labels    => false,      # Show labels on all entities (links and nodes)
  :inter_only    => false,      # Show only interconnection (switch) nodes
  :output        => "topology", # Default output file, ARGF.filename is used if available
  :formats       => [],         # Export formats (e.g ["png", "svg"])
  :include_guid  => false,      # include GUIDs in output
  :node_format   => nil,        # Custom node label format
  :switch_format => nil,        # Custom switch label format,
  :lid           => []          # By default, show all LIDs
}

# DATA STRUCTURES

class Node
    
    attr_accessor :lid, :guid, :name
    attr_accessor :switch, :total_ports, :ports
    
    def initialize(lid, guid, name)
        @lid, @guid, @name = lid, guid, name
        @ports = Hash.new
        @total_ports = 0
        @switch = false
    end
    
    def total_used
        @ports.size
    end
    
    def total_free
        total_ports - total_used
    end
    
    def connected?(port_num)
        @ports.key?(port_num)
    end
    
    def links
        @ports.values
    end
    
    def switch?
        !! @switch
    end
    
end

Link = Struct.new(:sw_lid, :sw_port, :sw_guid, :sw_name, :speed,
                  :peer_lid, :peer_port, :peer_guid, :peer_name)

# REGULAR EXPRESSIONS

# Match a double-quoted string
QUOTED = /[^"]+"([^"]*)"/

# Match an link definition. Expected lines looks like:
# <SW GUID> "<SW NAME>" <SW_ID> <SW_PORT> ... ==( ... <SPEED> ... )==>
# <PEER_GUID> <PEER_LID> <PEER_PORT> "<PEER_NAME>" ...

LINE_RE = /
    \s*(\w+)                # A switch GUID (hexa)
    #{QUOTED}               # followed by a quoted switch name
    \s+(\d+)                # followed by a switch LID (integer)
    \s+(\d+)                # followed by a switch port (integer)
    [^=]+                   # ...
    ==\(                    # ==(
    [^=]+                   # ...
    \s+(
        \d+\.\d+ |          # either a link speed (float) or
        Down                # "Down" for an unused port
    )
    [^=]+                   # ...
    \)==>                   # )==>
    \s+(\w*)                # A peer GUID (hexa)
    \s+(\d*)                # followed by a peer LID (integer)
    \s+(\d*)                # followed by a peer port (integer)
    #{QUOTED}               # followed by a quoted peer name
/x

# ARGUMENT PARSING

parser = OptionParser.new do |opt|
    opt.on("-l", "--lid lid1,lid2,lid3", Array, "Only show LID-related infos") do |list|
        SETTINGS[:lid] = list.map { |e| e.to_i }
    end

    opt.on("-g", "--guid") do
        SETTINGS[:include_guid] = true
    end

    opt.on("--bw", "Do not use colors in output") do
        SETTINGS[:use_color] = false
    end

    opt.on("-i", "--inter-only", "Show only interconnections") do
        SETTINGS[:inter_only] = true
    end

    opt.on("-f", "--formats x,y,z", Array, "Export to the specified formats (requires graphviz)") do |formats|
        SETTINGS[:formats] = formats
    end

    opt.on("-o", "--output OUTPUT", "Set output file basename (default: #{SETTINGS[:output]})") do |output|
        SETTINGS[:output] = output
    end
    
    opt.on("--switch-format FORMAT", "Informations to show in node labels") do |format|
       SETTINGS[:switch_format] = format
    end
      
    opt.on("--node-format FORMAT", "Information to show in switch labels") do |format|
        SETTINGS[:node_format] = format
    end

    opt.on_tail("-h", "--help", "Show this help") do
        puts opt
        exit
    end
end

parser.parse!

# INPUT FILE PARSING

nodes = {}
links = []

def get_node(nodes, lid, guid, name)
    nodes[lid] ||= Node.new(lid, guid, name)
end

if SETTINGS[:output] == "topology" && ARGF.filename != "-"
    SETTINGS[:output] = File.basename(ARGF.filename, File.extname(ARGF.filename))
end

ARGF.each_line do |line|
    if m = LINE_RE.match(line)
        sw_guid, sw_name, sw_lid, sw_port, speed,
            peer_guid, peer_lid, peer_port, peer_name = m.captures
        
        # Some outputs also include adapter => switch links, ignore them.
        if sw_name.include?("HCA")
            next
        end
        
        # Only keep the first part of the node name
        peer_name = peer_name.split(/\s+/).first || ""
        
        #puts '%s "%s" %d:%s' % [sw_guid, sw_name, sw_lid, sw_port]
        
        sw_lid, sw_port = sw_lid.to_i, sw_port.to_i
        peer_lid, peer_port = peer_lid.to_i, peer_port.to_i
        
        switch = get_node(nodes, sw_lid, sw_guid, sw_name)
        switch.total_ports += 1
        switch.switch = true
            
        if peer_name.size > 0
            peer = get_node(nodes, peer_lid, peer_guid, peer_name)
            
            # If there is already a link connected on the peer side,
            # either this is an interconnection link, or we have a big problem.
            # In both case, ignore this link
            unless peer.connected?(peer_port)
                link = Link.new(
                    sw_lid, sw_port, sw_guid, sw_name, 4 * speed.to_i,
                    peer_lid, peer_port, peer_guid, peer_name
                )
                
                switch.ports[sw_port] = link
                peer.ports[peer_port] = link
                links << link
            end
        else
            # The link is not connected
        end
    end
end

# OUTPUT FILE HELPERS

def ports_summary(switch)
    total_free = switch.total_free
    
    case total_free
    when 0; "full"
    when 1; "#{total_free} port free"
    else    "#{total_free} ports free"
    end
end

def ports_line(switch)
    free_bg = (SETTINGS[:use_color] ? "lawngreen" : "lightgray")
    html = ''
    
    (1..switch.total_ports).to_a.each do |port|
        if switch.connected?(port)
            html += "<TD PORT=\"p#{port}\">#{port}</TD>"
        else
            html += "<TD PORT=\"p#{port}\" BGCOLOR=\"#{free_bg}\">#{port}</TD>"
        end
    end
    
    html
end

def format_string(format, values)
    result = format
    values.each { |key, value| result.gsub!("%#{key}", value.to_s) }
    result
end

def switch_label(switch)
    # If a custom format was specified, use it
    if SETTINGS[:switch_format]
        format = SETTINGS[:switch_format]
    # else if a GUID must be included
    elsif SETTINGS[:include_guid]
        format = "switch_%lid (%guid, %report)"
    # else default format
    else
        format = "switch_%lid (%report)"
    end
    
    report = ports_summary(switch)
    ports = ports_line(switch)
    
    name = format_string(format, :lid => switch.lid, :guid => switch.guid,
                                 :name => switch.name, :report => report)
    
    '<TABLE><TR><TD COLSPAN="%d">%s</TD></TR><TR>%s</TR></TABLE>' % [
        switch.total_ports, name, ports
    ]
end

def node_label(node)
    # If a custom format was specified, use it
    if SETTINGS[:node_format]
        format = SETTINGS[:node_format]
    # else if a GUID must be included
    elsif SETTINGS[:include_guid]
        format = "%lid (%guid)"
    # else default format
    else
        format = "%name"
    end
    
    name = format_string(format, :lid => node.lid, :guid => node.guid,
                                 :name => node.name)
end

def interconnect?(link, nodes)
    nodes[link.sw_lid].switch? && nodes[link.peer_lid].switch?
end

# OUTPUT FILE GENERATION

# Having no nodes and no links is very suspect

if links.size == 0 && nodes.size == 0
    puts ">>> WARNING: Could not find any links or nodes in the given topology"
    puts ">>> WARNING: This script is now based on 'ibtopology --line' output"
end

# Keep only the links related to the specified LID, if required

if SETTINGS[:lid].size > 0
    lid = SETTINGS[:lid]
    puts ">>> Only keep hardware related to LID #{lid}"
    links = links.select { |l| (lid & [l.sw_lid, l.peer_lid]).size > 0 }
end

# Keep only the interconnection links, if required

if SETTINGS[:inter_only]
    puts ">>> Only keep interconnection links"
    links = links.select { |l| interconnect?(l, nodes) }
end

# Keep only the nodes used for the filtered links

nodes_lids = links.map { |l| [l.sw_lid, l.peer_lid] }.flatten.uniq
nodes = nodes_lids.inject({}) { |h, lid| h.update(lid => nodes[lid]) }

# Generate the graphviz output

graph = GraphViz.new(:G, :type => :digraph) do |g|
    g[:ratio] = 1
    g.edge[:dir] = "none"
    g.edge[:fontsize] = 8
    
    # Add nodes
    nodes.each do |lid, node|
        if node.switch?
            label = switch_label(node)
            g.add_nodes("switch_#{node.lid}", :label => "<#{label}>",
                :shape => "plaintext")
        else
            label = node_label(node)
            g.add_nodes("node_#{node.lid}", :label => label)
        end
    end
    
    # Add links
    links.each do |link|
        from = {"switch_#{link.sw_lid}" => "p" + link.sw_port.to_s}
        attributes = {}
        
        if interconnect?(link, nodes)
            to = {"switch_#{link.peer_lid}" => "p" + link.peer_port.to_s}
        else
            to = "node_#{link.peer_lid}"
        end
        
        if interconnect?(link, nodes)
            attributes[:color] = "firebrick"
            attributes[:style] = "bold"
        else
            case link.speed
            when 40
                attributes[:color] = "blue"
                attributes[:penwidth] = 2
            when 20
                attributes[:color] = "lightblue"
            end
        end
        
        # Remove color information if color support was disabled 
        unless SETTINGS[:use_color]
            attributes.delete(:color)
        end
        
        g.add_edges(from, to, attributes)
    end
end

output = SETTINGS[:output]

# Always generate dot output
puts "Generating #{output}.dot..."
graph.output(:dot => output + ".dot")

# Also generate the required formats
SETTINGS[:formats].each do |format|
    output_file = [output, format].join(".")
    puts "Generating #{output_file}..."
    graph.output(format.to_sym => output_file)
end
