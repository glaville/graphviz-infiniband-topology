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
require 'rubygems'
require 'graph'

#
# DEFAULT SETTINGS
#

settings = {
    :color      => true,
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
LINE_RE = /^\s+(\d+)\s+(\d+)\W+==[^=]+\s(\d+\.\d+|undefined)[^=]+==>\s*(\d*)\s*(\d*).*"([^"]*)"/

# Store informations associated to an IB Link
class Link < Struct.new(:sw_id, :sw_port, :sw_name, :peer_id,
						:peer_port, :peer_name, :speed)
    def h_name
        "switch_#{sw_id}"
    end
    
    def h_peer_number
        peer_name.scan(/\d+/).first
    end
    
    def ports
        "%d => %d" % [sw_port, peer_port]
    end
        
end

# Store informations associated to an IB Switch
class Switch
	
	attr_accessor :sw_id, :total_ports, :used_ports
	
	def initialize(id)
		@sw_id = id
		@total_ports = 0
		@used_ports = Array.new
	end
	
	def total_used
		@used_ports.size
	end
	
	def total_free
		total_ports - total_used
	end
	
end

#
# ARGUMENT PARSING
#

parser = OptionParser.new do |opt|
    opt.on("-l", "--lid [LID]", Integer, "Only show LID-linked links") do |i|
        settings[:lid] = i
    end
    
    opt.on("--bw", "Do not use colors in output") do
    	settings[:color] = false
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
    
    opt.on("--host [NAME]", String, "Show only this host connection") do |host|
        settings[:host] = host
    end
    
    opt.on("-f", "--formats x,y,z", Array, "Export to the specified formats (requires graphviz)") do |formats|
    	settings[:formats] = formats
    end
    
    opt.on("-o", "--output OUTPUT", "Set output file basename (default: #{settings[:output]})") do |output|
    	settings[:output] = output
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
switches = Hash.new { |h, sw_id| h[sw_id] = Switch.new(sw_id) }

ARGF.each_line do |line|
    if line =~ SW_RE
        sw_name = $1
    elsif line =~ LINE_RE
        sw_id, sw_port, speed, peer_id, peer_port, peer_name = $1.to_i, $2.to_i,
            4 * $3.to_f, $4.to_i, $5.to_i, $6
        
        # If we have some peer connected to this port, create a new link object
        # and increment switch used ports count
        if peer_name.size > 0
        	links << Link.new(sw_id, sw_port, sw_name, peer_id, peer_port, peer_name, speed)
        	#p "%d(%d) %s == %d(%d) %s" % [sw_id, sw_port, sw_name, peer_id, peer_port, peer_name]
       	end
       	
       	switches[sw_id].total_ports +=1
    end
end

# Associate each switch to its used ports
links.each do |link|
    switches[link.sw_id].used_ports << link.sw_port
end

#
# OUTPUT HELPERS
#

def switch_label(switch, free_color)
    '<TABLE><TR><TD COLSPAN="%d">Switch %d (%s)</TD></TR><TR>%s</TR></TABLE>' % [
    	switch.total_ports,
    	switch.sw_id,
    	free_label(switch.total_free),
    	(1..switch.total_ports).map { |port|
    		if switch.used_ports.include?(port)
    			'<TD PORT="p%1$d">%1$2d</TD>' % port
    		else
    			'<TD PORT="p%1$d" BGCOLOR="%2$s">%1$2d</TD>' % [port, free_color]
    		end
        }.join
    ]
end

def free_label(total_free)
    case total_free
    when 0; "full"
    when 1; "#{total_free} port free"
    else    "#{total_free} ports free"
    end
end

#
# OUTPUT DOT GENERATION
#

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
        nil
    end

    sw_list = links.select(&lid_filter).map { |e| e.sw_id }.uniq
    
    sw_list.each do |sw_id|
    	switch = switches[sw_id]
        label = switch_label(switch, settings[:color] ? "lawngreen" : "lightgray") 
        node("switch_#{sw_id}").attributes << "label =<#{label}>" << "shape = plaintext"
    end
    
    links.select(&lid_filter).each do |link|
        # Apply Host filter
        next if settings[:host] && link.h_peer_name != settings[:host]
        
        # Only show switch -> hosts links if required
        next if settings[:inter_only] && ! link.interconnect?
        
        # Only show switch - hosts links if required
        next if settings[:hosts_only] && link.interconnect?
        
        # Do not show interconnection links two times
        next if sw_list.include?(link.peer_id) && link.sw_id > link.peer_id
        
        from = [link.h_name, link.sw_port].join(":p")
        
        # If this is an interconnection link (ie the peer is a switch)
        if sw_list.include?(link.peer_id)
            to = ["switch_%d" % link.peer_id, link.peer_port].join(":p")
        else
            to = link.h_peer_number
        end
            
        e = edge(from, to)
        
        if settings[:color]
        	case link.speed
		    when 40
		    	e.attributes << "color = blue" << "pendwidth = 2"
		    when 20
		    	e.attributes << "color = lightblue"
		    end
		end
		
    end
    
    output = settings[:output]
    
    # Always generate dot output
    save output
    
    # Export output do selected formats by calling graphviz directly,
    # without regenerating the dot file each time (contrary to Graph#save)
    settings[:formats].each do |format|
    	puts "Exporting to #{output}.#{format}..."
    	system "dot -T#{format} #{output}.dot > #{output}.#{format}" if format
    end
end
