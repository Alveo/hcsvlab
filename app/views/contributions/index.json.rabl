#{
#	"own": [
#		{
#			"id" : 1, 
#			"name" : "ace", 
#			"url" : "https://app.alveo.edu.au/contrib/1"
#		},
#		{
#			"id" : 2, 
#			"name" : "cooee", 
#			"url" : "https://app.alveo.edu.au/contrib/2"
#		}
#	],
#	"shared": [
#		{
#			"id" : 3, 
#			"name" : "ice", 
#			"url": "https://app.alveo.edu.au/contrib/3", 
#			"accessible" : true
#		}, 
#		{
#			"id" : 4, 
#			"name" : "austalk", 
#			"url": "https://app.alveo.edu.au/contrib/4", 
#			"accessible" : false
#		}
#	]
#}

object false

#own contribution
own_data = []
node(:own) do
  @own_contributions.each do |c|
    hash = {}
    hash[:id] = c.id
    hash[:name] = c.name
    hash[:url] = contrib_show_url(c.id)

    own_data << hash.clone
  end

  own_data
end

#shared contribution
shared_data = []
node(:shared) do
  @shared_contributions.each do |c|
    hash = {}
    hash[:id] = c[:id]
    hash[:name] = c[:name]
    hash[:url] = c[:url]
    hash[:accessible] = c[:accessible]

    shared_data << hash.clone
  end

  shared_data
end

