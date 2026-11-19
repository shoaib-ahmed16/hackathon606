package com.yashasvi.hackathon.repository;

import com.yashasvi.hackathon.domain.UsersDetails;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.Optional;

@Repository
public interface UsersDetailsRepository extends JpaRepository<UsersDetails,Integer> {
     Optional<UsersDetails> findByEmail(String email);
}
