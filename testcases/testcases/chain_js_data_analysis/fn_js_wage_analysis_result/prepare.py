#!/bin/python
import couchdb

couch = couchdb.Server("http://admin:password@localhost:5984")

if not "wage-statistics" in couch:
    couch.create("wage-statistics")
