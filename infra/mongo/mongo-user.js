db = db.getSiblingDB("admin")

db.createUser({
  user: "root",
  pwd: "rootpass",
  roles: [{ role: "root", db: "admin" }]
})

db.createRole({
  role: "exporterSystemVersionRead",
  privileges: [
    {
      resource: { db: "admin", collection: "system.version" },
      actions: ["find"]
    }
  ],
  roles: []
})

db.createUser({
  user: "mongo-exporter",
  pwd: "mongo-exporterpass",
  roles: [
    { role: "clusterMonitor", db: "admin" },
    { role: "readAnyDatabase", db: "admin" },
    { role: "read", db: "local" },
    { role: "exporterSystemVersionRead", db: "admin" }
  ]
})

db.createUser({
  user: "chatuser",
  pwd: "chatpass",
  roles: [{ role: "readWrite", db: "chat" }]
})
