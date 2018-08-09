#
# {"contributions" :
#  [{"id" : 1, ""name" : "ace", "url" : "https://app.alveo.edu.au/contrib/1"},
#  {"id" : 2, , "name" : "cooee", "url" : "https://app.alveo.edu.au/contrib/2"},
#  {"id" : 3, "name" : "ice", "url": "https://app.alveo.edu.au/contrib/3"},
#  {"id" : 4, "name" : "austalk", "url": "https://app.alveo.edu.au/contrib/4"}]
#  }
#

collection @contributions => "contributions"
attributes :id, :name
node(:url) {|c| contrib_show_url(c.id)}