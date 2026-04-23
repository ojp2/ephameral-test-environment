-- Applied by the workflow via kubectl exec into the mysql pod before ArgoCD syncs the wager app
CREATE TABLE IF NOT EXISTS wager_transactions (
    id             BIGINT        AUTO_INCREMENT PRIMARY KEY,
    transaction_id VARCHAR(100)  NOT NULL UNIQUE,
    game_code      VARCHAR(10)   NOT NULL,
    player_id      VARCHAR(100)  NOT NULL,
    wager_amount   DECIMAL(10,2) NOT NULL,
    status         VARCHAR(50)   NOT NULL,  -- OK | NO_FUNDS | HOST_NO_ISSUE | GDS_ERROR | ESB_ERROR
    created_at     DATETIME      NOT NULL DEFAULT NOW(),

    INDEX idx_game_code  (game_code),
    INDEX idx_player_id  (player_id),
    INDEX idx_status     (status),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
