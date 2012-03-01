#!/usr/bin/env ruby
# encoding: UTF-8
#
# Copyright (C) 2012 Guillaume Laville <laville.guillaume@gmail.com>
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
# - graph gem (gem install graph)
#
# USAGE
#
#   topology.rb -f png <iblinkinfo.pl output file> OR
#   iblinkinfo.pl | topology.rb -f png

require 'optparse'
require 'graph'

#
# DEFAULT SETTINGS
#

settings = {
    :all_labels => false,      # Show labels on all entities (links and nodes)
    :inter_only => false,      # Show only interconnection (switch) nodes
    :hosts_only => false,      # Show only hosts (endpoints) nodes
    :output     => "topology", # Default output file
    :formats    => []          # Export formats (e.g ["png", "svg"])
}


#
# DATA STRUCTURES DEFINITION
#

# Switch header line format
SW_RE   = /^Switch\s+\w+\s+(.*)\:$/

# Link information line format
LINE_RE = /^\s+(\d+)\s+(\d+)\W+==[^=]+\s(\d+\.\d+|undefined)[^=]++==>\s+(\d+)\s+(\d+).*"([^"]+)"/

# Store informations associated to an IB Link
class Link < Struct.new(:sw_id, :sw_port, :sw_name, :peer_id,
						:peer_port, :peer_name, :speed)
    
    def host?
        peer_name.include?("mesocomte")
    end
    
    def interconnect?
        peer_name.include?("Voltaire")
    end
    
    def h_name
        "switch_#{sw_id}"
    end
    
    def h_peer_name
        host? ? peer_name.scan(/\d+/).first : "switch_#{peer_id}"
    end
    
    def ports
        "%d => %d" % [sw_port, peer_port]
    end
        
end

#
# ARGUMENT PARSING
#

parser = OptionParser.new do |opt|
    opt.on("-l", "--lid [LID]", Integer, "Only show LID-linked links") do |i|
        settings[:lid] = i
    end
    
    opt.on("-a", "--all-labels", "Show all labels (pretty crowdy o)") do
        settings[:all_labels] = true
    end
    
    opt.on("-i", "--inter-only", "Show only interconnections") do
        settings[:inter_only] = true
    end
    
    opt.on("-n", "--hosts-only", "Show only hosts connections") do
        settings[:hosts_only] = true
    end
    
    opt.on("-f", "--formats x,y,z", Array, "Export to the specified formats (requires graphviz)") do |formats|
    	settings[:formats] = formats
    end
    
    opt.on("-o", "--output OUTPUT", "Set output file basename (default: #{settings[:output]})") do |output|
    	settings[:output] = output
    end
    
    opt.on("--host [NAME]", String, "Show only this host connection") do |host|
        settings[:host] = host
    end
    
    opt.on_tail("-h", "--help", "Show this help") do
        puts opt
        exit
    end
end

parser.parse!

# START MONKEY-PATCH
# The non-patched version of Graph::Edge provided by the graph gem
# considers edge with "node1:1" and "node1:2" labels as referencing
# distinct nodes: This patched to_s allows correct dot generation in this case.

class Graph
    class Edge
        def to_s
            fromto = "%s -> %s" % [
            	from.name.split(":").map {|e| "%p" % e}.join(":"),
            	to.name.split(":").map {|e| "%p" % e}.join(":")
            ]
            if self.attributes? then
              "%-20s [ %-20s ]" % [fromto, attributes.join(',')]
            else
              fromto
            end
        end
    end
end

# END OF THE MONKEY-PATCH

#
# INPUT FILE PARSING
#

sw_name = nil
links = Array.new

ARGF.each_line do |line|
    if line =~ SW_RE
        sw_name = $1
    elsif line =~ LINE_RE
        sw_id, sw_port, speed, peer_id, peer_port, peer_name = $1.to_i, $2.to_i,
            4 * $3.to_f, $4.to_i, $5.to_i, $6
        links << Link.new(sw_id, sw_port, sw_name, peer_id, peer_port, peer_name, speed) 
        # p "%d(%d) %s == %d(%d) %s" % [sw_id, sw_port, sw_name, peer_id, peer_port, peer_name]
    end
end

#
# OUTPUT HELPERS
#

def switch_label(name, ports)
    '<TABLE><TR><TD COLSPAN="36">%s (%s)</TD></TR><TR>%s</TR></TABLE>' %
        [name, free_label(ports), (1..36).to_a.map { |e| port_label(e, ports) }.join]
end

def free_label(ports)
    free = 36 - ports.size
    case free
    when 0; "full"
    when 1; "#{free} port free"
    else "#{free} ports free"
    end
end

def port_label(i, ports)
    (ports.has_key?(i) ? '<TD PORT="p%d">%d</TD>' : '<TD PORT="p%d" BGCOLOR="lawngreen">%d</TD>') % [i, i]
end

#
# OUTPUT DOT GENERATION
#

used_ports = Hash.new { |h, k| h[k] = Hash.new }

links.each do |link|
    used_ports[link.sw_id][link.sw_port] = link.peer_port
end

digraph do
    graph_attribs <<   #"overlap = scalexy" <<
                        "ratio = 1"
                        #"layout = neato" <<
                        #"concentrate = false" <<
                        #"layout = circo" <<
                        # "overlap = false"
                        #"overlap_scaling = 4"
                        #"splines = true"
    # node_attribs << "rank = max"
    edge_attribs << "dir = none" << "fontsize  = 8" #  << "constraint = false"
    
    lid_filter = if settings[:host]
        proc { |e| e.h_peer_name == settings[:host] }
    elsif settings[:lid]
        proc { |e| e.sw_id == settings[:lid] || e.peer_id == settings[:lid] }
    else
        proc { |e| true }
    end
    
    sw_list = links.select(&lid_filter).map(&:sw_id).uniq
    
    sw_list.each do |id|
        ports = (1..36).to_a.map { |e| "<p%d> %d" % [e, e] }.join("|")
        node("switch_#{id}").attributes << (%Q{label =<%s>} % switch_label("Switch #{id}", used_ports[id])) << "shape = plaintext"
        #label(switch_label("Switch #{id}")) #"{Switch #{id}\n|{ #{ports} }}").attributes << "shape = record"
    end
    
    links.each do |link|
        # Apply Host filter
        next if settings[:host] && link.h_peer_name != settings[:host]
        
        # Apply LID filter to only display equipment-related links
        next unless lid_filter.call(link)
        
        # Only show interconnect links if required
        next if settings[:inter_only] && ! link.interconnect?
        
        # Only show switch - hosts links if required
        next if settings[:hosts_only] && link.interconnect?
        
        # Do not show duplicated interconnection links
        next if link.interconnect? && link.sw_id > link.peer_id
        
        from = [link.h_name, link.sw_port].join(":p")
        if link.interconnect?
            to = [link.h_peer_name, link.peer_port].join(":p")
        else
            to = link.h_peer_name
        end
            
        e = edge(from, to)
        e.attributes << "color = blue"
        # e.attributes << (link.speed == 40 ? 'color = blue' : 'color = lightblue')
        e.attributes << "penwidth = 2" if link.speed == 40 
    end
    
    settings[:formats].each do |format|
    	output = settings[:output]
    	puts "Exporting to #{output}.#{format}..."
    	save output, format
    end
end
