from pathlib import Path


path = Path("drivers/net/ethernet/broadcom/genet/bcmgenet.c")
src = path.read_text()


def replace_one(options, new):
    global src
    if isinstance(options, str):
        options = [options]

    for old in options:
        if old in src:
            src = src.replace(old, new, 1)
            return

    raise SystemExit(f"missing patch anchor: {options[0][:80]}")


repls = [
    (
        "priv->base = devm_platform_ioremap_resource(pdev, 0);",
        'dev_info(&pdev->dev, "FROG-HACK probe: irq0=%d irq1=%d wol_irq=%d\\n",\n'
        "\t priv->irq0, priv->irq1, priv->wol_irq);\n"
        "\tpriv->base = devm_platform_ioremap_resource(pdev, 0);",
    ),
    (
        ["err = register_netdev(dev);", "ret = register_netdev(dev);"],
        'dev_info(&pdev->dev, "FROG-HACK hw: version=%d txq=%u rxq=%u tdma=0x%x rdma=0x%x words_per_bd=%u\\n",\n'
        "\t priv->version, priv->hw_params->tx_queues, priv->hw_params->rx_queues,\n"
        "\t priv->hw_params->tdma_offset, priv->hw_params->rdma_offset,\n"
        "\t priv->hw_params->words_per_bd);\n\n"
        "\terr = register_netdev(dev);",
    ),
    (
        "ret = request_irq(priv->irq0, bcmgenet_isr0, IRQF_SHARED,",
        'netdev_warn(dev, "FROG-HACK open: requesting irq0=%d irq1=%d phy_if=%d internal_phy=%d\\n",\n'
        "\t\t    priv->irq0, priv->irq1, priv->phy_interface, priv->internal_phy);\n\n"
        "\tret = request_irq(priv->irq0, bcmgenet_isr0, IRQF_SHARED,",
    ),
    (
        "status = bcmgenet_intrl2_1_readl(priv, INTRL2_CPU_STAT) &\n\t\t~bcmgenet_intrl2_1_readl(priv, INTRL2_CPU_MASK_STATUS);",
        "status = bcmgenet_intrl2_1_readl(priv, INTRL2_CPU_STAT) &\n\t\t~bcmgenet_intrl2_1_readl(priv, INTRL2_CPU_MASK_STATUS);\n\n"
        "\tif (status)\n"
        '\t\tnetdev_warn(priv->dev, "FROG-HACK isr1 pre-clear: irq=%d status=0x%x mask=0x%x\\n",\n'
        "\t\t\t    irq, status, bcmgenet_intrl2_1_readl(priv, INTRL2_CPU_MASK_STATUS));",
    ),
    (
        "status = bcmgenet_intrl2_0_readl(priv, INTRL2_CPU_STAT) &\n\t\t~bcmgenet_intrl2_0_readl(priv, INTRL2_CPU_MASK_STATUS);",
        "status = bcmgenet_intrl2_0_readl(priv, INTRL2_CPU_STAT) &\n\t\t~bcmgenet_intrl2_0_readl(priv, INTRL2_CPU_MASK_STATUS);\n\n"
        "\tif (status)\n"
        '\t\tnetdev_warn(priv->dev, "FROG-HACK isr0 pre-clear: irq=%d status=0x%x mask=0x%x\\n",\n'
        "\t\t\t    irq, status, bcmgenet_intrl2_0_readl(priv, INTRL2_CPU_MASK_STATUS));",
    ),
    (
        'netif_dbg(priv, tx_err, dev, "bcmgenet_timeout\\n");',
        'netif_dbg(priv, tx_err, dev, "bcmgenet_timeout\\n");\n\n'
        '\tnetdev_warn(dev, "FROG-HACK timeout q=%u: INTRL2_0 stat=0x%x mask=0x%x INTRL2_1 stat=0x%x mask=0x%x\\n",\n'
        "\t\t    txqueue,\n"
        "\t\t    bcmgenet_intrl2_0_readl(priv, INTRL2_CPU_STAT),\n"
        "\t\t    bcmgenet_intrl2_0_readl(priv, INTRL2_CPU_MASK_STATUS),\n"
        "\t\t    bcmgenet_intrl2_1_readl(priv, INTRL2_CPU_STAT),\n"
        "\t\t    bcmgenet_intrl2_1_readl(priv, INTRL2_CPU_MASK_STATUS));\n"
        '\tnetdev_warn(dev, "FROG-HACK timeout q=%u: TDMA ctrl=0x%x stat=0x%x RDMA ctrl=0x%x stat=0x%x\\n",\n'
        "\t\t    txqueue,\n"
        "\t\t    bcmgenet_tdma_readl(priv, DMA_CTRL),\n"
        "\t\t    bcmgenet_tdma_readl(priv, DMA_STATUS),\n"
        "\t\t    bcmgenet_rdma_readl(priv, DMA_CTRL),\n"
        "\t\t    bcmgenet_rdma_readl(priv, DMA_STATUS));\n"
        '\tnetdev_warn(dev, "FROG-HACK timeout q=%u: TDMA ring%u prod=0x%x cons=0x%x read=0x%x write=0x%x\\n",\n'
        "\t\t    txqueue, txqueue,\n"
        "\t\t    bcmgenet_tdma_ring_readl(priv, txqueue, TDMA_PROD_INDEX),\n"
        "\t\t    bcmgenet_tdma_ring_readl(priv, txqueue, TDMA_CONS_INDEX),\n"
        "\t\t    bcmgenet_tdma_ring_readl(priv, txqueue, TDMA_READ_PTR),\n"
        "\t\t    bcmgenet_tdma_ring_readl(priv, txqueue, TDMA_WRITE_PTR));\n"
        '\tnetdev_warn(dev, "FROG-HACK timeout q=%u: RDMA ring0 prod=0x%x cons=0x%x read=0x%x write=0x%x\\n",\n'
        "\t\t    txqueue,\n"
        "\t\t    bcmgenet_rdma_ring_readl(priv, 0, RDMA_PROD_INDEX),\n"
        "\t\t    bcmgenet_rdma_ring_readl(priv, 0, RDMA_CONS_INDEX),\n"
        "\t\t    bcmgenet_rdma_ring_readl(priv, 0, RDMA_READ_PTR),\n"
        "\t\t    bcmgenet_rdma_ring_readl(priv, 0, RDMA_WRITE_PTR));",
    ),
]

for old, new in repls:
    replace_one(old, new)

path.write_text(src)
