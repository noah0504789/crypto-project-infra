db = db.getSiblingDB("admin")

// 비밀번호는 컨테이너 환경변수(= infra/.env)에서 주입한다. 평문 하드코딩 금지.
db.createUser({
  user: process.env.MONGO_ROOT_USERNAME,
  pwd: process.env.MONGO_ROOT_PASSWORD,
  roles: [{ role: "root", db: "admin" }]
})

db.createUser({
  user: "chatuser",
  pwd: process.env.MONGO_CHAT_PASSWORD,
  roles: [{ role: "readWrite", db: "chat" }]
})

db.createUser({
  user: "notificationuser",
  pwd: process.env.MONGO_NOTIFICATION_PASSWORD,
  roles: [{ role: "readWrite", db: "notification" }]
})

db.createUser({
  user: "mongo-exporter",
  pwd: process.env.MONGO_EXPORTER_PASSWORD,
  roles: [
    { role: "clusterMonitor", db: "admin" },
    { role: "readAnyDatabase", db: "admin" },
    { role: "read", db: "local" },
    { role: "exporterSystemVersionRead", db: "admin" }
  ]
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
