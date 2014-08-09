#!/usr/bin/python

print 'Content-Type: application/json'
print 

import cgi
import cgitb
import urllib, urllib2

cgitb.enable()

form = cgi.FieldStorage()

q = form.getvalue('q', '5109')

if len(q) > 0:
    url = ("http://map.naver.com/pubtrans/getBusRouteInfo.nhn?busID=" +
            urllib.quote_plus(q))
    req = urllib2.Request(url, headers={ 'User-Agent': 'Mozilla/5.0' })
    print urllib2.urlopen(req).read()

