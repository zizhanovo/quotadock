## 改了什么 / 为什么

<!-- 关联 issue（若有）：Closes #N -->

## 自查

- [ ] `swift build` 通过
- [ ] `swift test` 通过（新逻辑有对应测试）
- [ ] `./build.sh` 产出可运行 bundle；`--version` 正常
- [ ] UI 改动跑了离屏渲染：`QUOTADOCK_RENDER=1 .build/debug/QuotaDock`（亮/暗两态）
- [ ] 不引入第三方运行时依赖（零依赖约束）
- [ ] 数据源改动不把凭据写进日志/缓存

## 截图（UI 改动必附）
