use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use usd8_tee_job_api::JobStore;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "outcome",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Semantic {
    NoDrop,
    Qualifying {
        reference_block: u64,
        observation_block: u64,
    },
}
#[derive(Clone, Debug)]
pub enum CheckError {
    Unavailable,
    Active,
    Unapproved,
}
pub struct Binding {
    pub commitment: String,
    pub head: u64,
    pub finalized: u64,
    pub max_age: u64,
}
#[async_trait]
pub trait AdvisorySource: Send + Sync {
    async fn binding(&self) -> Result<Binding, CheckError>;
    async fn refresh(&self) -> Result<Semantic, CheckError>;
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Advisory {
    pub checked_at: u64,
    pub expires_at: u64,
    pub configuration: String,
    pub result: Semantic,
}
pub struct Decision {
    pub fresh: bool,
    pub advisory: Option<Advisory>,
}
#[derive(Default, Serialize, Deserialize)]
struct Record {
    attempt_at: Option<u64>,
    snapshot: Option<Advisory>,
}

fn eligible(result: &Semantic, binding: &Binding) -> bool {
    if binding.head == 0
        || binding.finalized == 0
        || binding.finalized > binding.head
        || binding.max_age == 0
        || binding.commitment.is_empty()
    {
        return false;
    }
    match result {
        Semantic::NoDrop => true,
        Semantic::Qualifying {
            reference_block,
            observation_block,
        } => {
            *reference_block > 0
                && *reference_block < binding.head
                && binding.head - reference_block <= binding.max_age
                && *observation_block > *reference_block
                && *observation_block <= binding.finalized
        }
    }
}

pub const CACHE_BUDGET: std::time::Duration = std::time::Duration::from_secs(24);

// Check before polling, not only after: an already-expired ready future must
// never begin submission. A biased timer also wins an exact-deadline tie.
pub async fn within_deadline<T>(
    deadline: tokio::time::Instant,
    future: impl std::future::Future<Output = T>,
) -> Result<T, CheckError> {
    if tokio::time::Instant::now() >= deadline {
        return Err(CheckError::Unavailable);
    }
    let result = tokio::select! {
        biased;
        _ = tokio::time::sleep_until(deadline) => return Err(CheckError::Unavailable),
        result = future => result,
    };
    if tokio::time::Instant::now() >= deadline {
        return Err(CheckError::Unavailable);
    }
    Ok(result)
}

// Include elapsed I/O time in display expiry and authorization freshness.
pub async fn check<S: JobStore, P: AdvisorySource>(
    store: &S,
    source: &P,
    namespace: &str,
    now: u64,
    deadline: tokio::time::Instant,
) -> Result<Decision, CheckError> {
    let started = tokio::time::Instant::now();
    let deadline = deadline.min(started + CACHE_BUDGET);
    let mut retained = None;
    let mut decision = match within_deadline(
        deadline,
        check_inner(store, source, namespace, now, deadline, &mut retained),
    )
    .await
    {
        Ok(result) => result?,
        Err(_) => Decision {
            fresh: false,
            advisory: retained,
        },
    };
    let returned_at = now.saturating_add(started.elapsed().as_secs());
    decision.advisory = decision.advisory.filter(|s| returned_at < s.expires_at);
    decision.fresh &= decision
        .advisory
        .as_ref()
        .is_some_and(|s| returned_at.saturating_sub(s.checked_at) < 60);
    Ok(decision)
}

// A single object contains both the attempt reservation and the last semantic
// snapshot. CAS fences publication; failures never replace the retained result.
async fn check_inner<S: JobStore, P: AdvisorySource>(
    store: &S,
    source: &P,
    namespace: &str,
    now: u64,
    deadline: tokio::time::Instant,
    fallback: &mut Option<Advisory>,
) -> Result<Decision, CheckError> {
    use sha2::{Digest, Sha256};
    let key = format!(
        "control/open-advisory/v1/{}.json",
        hex::encode(Sha256::digest(namespace.as_bytes()))
    );
    let object = store
        .get_versioned(&key, 16_384)
        .await
        .map_err(|_| CheckError::Unavailable)?;
    let mut record: Record = match &object {
        Some(object) => {
            serde_json::from_slice(&object.bytes).map_err(|_| CheckError::Unavailable)?
        }
        None => Record::default(),
    };
    let retained = record.snapshot.clone().filter(|s| {
        now >= s.checked_at
            && now < s.expires_at
            && s.expires_at == s.checked_at.saturating_add(3600)
    });
    *fallback = retained.clone();
    let binding = match source.binding().await {
        Ok(binding) => binding,
        Err(CheckError::Unavailable) => {
            return Ok(Decision {
                fresh: false,
                advisory: retained,
            });
        }
        Err(error) => return Err(error),
    };
    let prior = retained.filter(|s| s.configuration == binding.commitment);
    *fallback = prior.clone();
    if let Some(snapshot) = prior
        .as_ref()
        .filter(|s| now - s.checked_at < 60 && eligible(&s.result, &binding))
    {
        return Ok(Decision {
            fresh: true,
            advisory: Some(snapshot.clone()),
        });
    }
    if record
        .attempt_at
        .is_some_and(|attempt| now < attempt.saturating_add(60))
    {
        return Ok(Decision {
            fresh: false,
            advisory: prior,
        });
    }
    record.attempt_at = Some(now);
    let bytes = serde_json::to_vec(&record).map_err(|_| CheckError::Unavailable)?;
    if !store
        .compare_exchange(&key, object.as_ref().map(|o| o.revision.as_str()), &bytes)
        .await
        .map_err(|_| CheckError::Unavailable)?
    {
        return Ok(Decision {
            fresh: false,
            advisory: prior,
        });
    }
    let reserved = store
        .get_versioned(&key, 16_384)
        .await
        .map_err(|_| CheckError::Unavailable)?
        .ok_or(CheckError::Unavailable)?;
    if reserved.bytes != bytes {
        return Err(CheckError::Unavailable);
    }
    // Leave enough of the durable 60-second reservation for the bounded scan.
    // Slow S3/RPC admission must not start historical work near lease expiry.
    if tokio::time::Instant::now() >= deadline {
        return Ok(Decision {
            fresh: false,
            advisory: prior,
        });
    }
    let result = match within_deadline(deadline, source.refresh()).await {
        Ok(Ok(result)) => result,
        _ => {
            return Ok(Decision {
                fresh: false,
                advisory: prior,
            });
        }
    };
    let current = match source.binding().await {
        Ok(current) if current.commitment == binding.commitment => current,
        Err(CheckError::Unavailable) => {
            return Ok(Decision {
                fresh: false,
                advisory: prior,
            });
        }
        _ => {
            return Ok(Decision {
                fresh: false,
                advisory: None,
            });
        }
    };
    if !eligible(&result, &current) {
        return Ok(Decision {
            fresh: false,
            advisory: prior,
        });
    }
    let snapshot = Advisory {
        checked_at: now,
        expires_at: now.checked_add(3600).ok_or(CheckError::Unavailable)?,
        configuration: binding.commitment,
        result,
    };
    record.snapshot = Some(snapshot.clone());
    let bytes = serde_json::to_vec(&record).map_err(|_| CheckError::Unavailable)?;
    if !store
        .compare_exchange(&key, Some(&reserved.revision), &bytes)
        .await
        .map_err(|_| CheckError::Unavailable)?
    {
        return Err(CheckError::Unavailable);
    }
    Ok(Decision {
        fresh: true,
        advisory: Some(snapshot),
    })
}
