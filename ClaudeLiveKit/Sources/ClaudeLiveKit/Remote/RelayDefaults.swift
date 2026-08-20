/// L'indirizzo del relay di Purple Heads, usato quando nessuno ne indica un altro.
///
/// Non è un segreto e non ha senso trattarlo come tale: la credenziale è
/// l'identificativo che ogni Mac si genera, e i contenuti sono sigillati con una
/// chiave che al relay non arriva mai. Chi conosce questo indirizzo può
/// constatare che il relay è vivo, e nient'altro.
///
/// Scritto qui perché un'app installata da qualcuno che non l'ha costruita non
/// può chiedere un indirizzo — chiederlo era esattamente il passo che rendeva
/// tutto questo non distribuibile. Il campo nelle impostazioni resta per chi
/// vuole pubblicare un relay suo.
public enum RelayDefaults {
    public static let address = "https://claude-live-relay.purpleheads.workers.dev"
}
