export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      achievement_definitions: {
        Row: {
          audience: Database["public"]["Enums"]["challenge_audience"]
          code: string
          created_at: string
          description: string | null
          icon: string | null
          id: string
          name: string
          status: string
          studio_id: string | null
          threshold: number | null
          trigger_type: string
        }
        Insert: {
          audience?: Database["public"]["Enums"]["challenge_audience"]
          code: string
          created_at?: string
          description?: string | null
          icon?: string | null
          id?: string
          name: string
          status?: string
          studio_id?: string | null
          threshold?: number | null
          trigger_type: string
        }
        Update: {
          audience?: Database["public"]["Enums"]["challenge_audience"]
          code?: string
          created_at?: string
          description?: string | null
          icon?: string | null
          id?: string
          name?: string
          status?: string
          studio_id?: string | null
          threshold?: number | null
          trigger_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "achievement_definitions_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "achievement_definitions_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_insights: {
        Row: {
          action_payload: Json
          action_type: string
          actioned_at: string | null
          actioned_by: string | null
          created_at: string
          dismissed_at: string | null
          estimated_impact_cents: number | null
          for_date: string
          id: string
          input_snapshot: Json | null
          model: string | null
          observation: string
          prompt_version: string | null
          recommended_action: string
          severity: string
          status: Database["public"]["Enums"]["insight_status"]
          studio_id: string
          subject_id: string | null
          subject_type: string | null
          title: string
          type: string
          updated_at: string
          why_it_matters: string
        }
        Insert: {
          action_payload?: Json
          action_type: string
          actioned_at?: string | null
          actioned_by?: string | null
          created_at?: string
          dismissed_at?: string | null
          estimated_impact_cents?: number | null
          for_date: string
          id?: string
          input_snapshot?: Json | null
          model?: string | null
          observation: string
          prompt_version?: string | null
          recommended_action: string
          severity?: string
          status?: Database["public"]["Enums"]["insight_status"]
          studio_id: string
          subject_id?: string | null
          subject_type?: string | null
          title: string
          type: string
          updated_at?: string
          why_it_matters: string
        }
        Update: {
          action_payload?: Json
          action_type?: string
          actioned_at?: string | null
          actioned_by?: string | null
          created_at?: string
          dismissed_at?: string | null
          estimated_impact_cents?: number | null
          for_date?: string
          id?: string
          input_snapshot?: Json | null
          model?: string | null
          observation?: string
          prompt_version?: string | null
          recommended_action?: string
          severity?: string
          status?: Database["public"]["Enums"]["insight_status"]
          studio_id?: string
          subject_id?: string | null
          subject_type?: string | null
          title?: string
          type?: string
          updated_at?: string
          why_it_matters?: string
        }
        Relationships: [
          {
            foreignKeyName: "ai_insights_actioned_by_fkey"
            columns: ["actioned_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_insights_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_insights_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_logs: {
        Row: {
          action: string
          actor_user_id: string | null
          after: Json | null
          before: Json | null
          created_at: string
          entity_id: string | null
          entity_table: string
          id: string
          ip: unknown
          studio_id: string
        }
        Insert: {
          action: string
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          entity_id?: string | null
          entity_table: string
          id?: string
          ip?: unknown
          studio_id: string
        }
        Update: {
          action?: string
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          entity_id?: string | null
          entity_table?: string
          id?: string
          ip?: unknown
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "audit_logs_actor_user_id_fkey"
            columns: ["actor_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_logs_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_logs_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      bookings: {
        Row: {
          booked_at: string
          cancelled_at: string | null
          cancelled_by: string | null
          created_at: string
          credit_entry_id: string | null
          fee_charged_cents: number
          id: string
          is_demo: boolean
          is_late_cancel: boolean
          member_id: string
          membership_id: string | null
          occurrence_id: string
          overridden_rules: string[] | null
          override_reason: string | null
          payment_source: Database["public"]["Enums"]["payment_source"] | null
          source: Database["public"]["Enums"]["booking_source"]
          status: Database["public"]["Enums"]["booking_status"]
          studio_id: string
          updated_at: string
          waitlist_position: number | null
        }
        Insert: {
          booked_at?: string
          cancelled_at?: string | null
          cancelled_by?: string | null
          created_at?: string
          credit_entry_id?: string | null
          fee_charged_cents?: number
          id?: string
          is_demo?: boolean
          is_late_cancel?: boolean
          member_id: string
          membership_id?: string | null
          occurrence_id: string
          overridden_rules?: string[] | null
          override_reason?: string | null
          payment_source?: Database["public"]["Enums"]["payment_source"] | null
          source?: Database["public"]["Enums"]["booking_source"]
          status?: Database["public"]["Enums"]["booking_status"]
          studio_id: string
          updated_at?: string
          waitlist_position?: number | null
        }
        Update: {
          booked_at?: string
          cancelled_at?: string | null
          cancelled_by?: string | null
          created_at?: string
          credit_entry_id?: string | null
          fee_charged_cents?: number
          id?: string
          is_demo?: boolean
          is_late_cancel?: boolean
          member_id?: string
          membership_id?: string | null
          occurrence_id?: string
          overridden_rules?: string[] | null
          override_reason?: string | null
          payment_source?: Database["public"]["Enums"]["payment_source"] | null
          source?: Database["public"]["Enums"]["booking_source"]
          status?: Database["public"]["Enums"]["booking_status"]
          studio_id?: string
          updated_at?: string
          waitlist_position?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "bookings_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bookings_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bookings_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bookings_membership_id_fkey"
            columns: ["membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bookings_occurrence_id_fkey"
            columns: ["occurrence_id"]
            isOneToOne: false
            referencedRelation: "class_occurrences"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bookings_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bookings_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      challenge_participants: {
        Row: {
          audience: Database["public"]["Enums"]["challenge_audience"]
          challenge_id: string
          completed_at: string | null
          created_at: string
          goal_value: number
          id: string
          instructor_id: string | null
          joined_at: string
          last_progress_at: string | null
          member_id: string | null
          progress: number
          rank: number | null
          studio_id: string
          updated_at: string
        }
        Insert: {
          audience: Database["public"]["Enums"]["challenge_audience"]
          challenge_id: string
          completed_at?: string | null
          created_at?: string
          goal_value: number
          id?: string
          instructor_id?: string | null
          joined_at?: string
          last_progress_at?: string | null
          member_id?: string | null
          progress?: number
          rank?: number | null
          studio_id: string
          updated_at?: string
        }
        Update: {
          audience?: Database["public"]["Enums"]["challenge_audience"]
          challenge_id?: string
          completed_at?: string | null
          created_at?: string
          goal_value?: number
          id?: string
          instructor_id?: string | null
          joined_at?: string
          last_progress_at?: string | null
          member_id?: string | null
          progress?: number
          rank?: number | null
          studio_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "challenge_participants_challenge_id_fkey"
            columns: ["challenge_id"]
            isOneToOne: false
            referencedRelation: "challenges"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_participants_instructor_id_fkey"
            columns: ["instructor_id"]
            isOneToOne: false
            referencedRelation: "instructors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_participants_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_participants_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_participants_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_participants_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      challenge_progress_events: {
        Row: {
          booking_id: string | null
          challenge_id: string
          created_at: string
          delta: number
          id: string
          instructor_id: string | null
          member_id: string | null
          occurred_at: string
          occurrence_id: string | null
          studio_id: string
        }
        Insert: {
          booking_id?: string | null
          challenge_id: string
          created_at?: string
          delta: number
          id?: string
          instructor_id?: string | null
          member_id?: string | null
          occurred_at: string
          occurrence_id?: string | null
          studio_id: string
        }
        Update: {
          booking_id?: string | null
          challenge_id?: string
          created_at?: string
          delta?: number
          id?: string
          instructor_id?: string | null
          member_id?: string | null
          occurred_at?: string
          occurrence_id?: string | null
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "challenge_progress_events_booking_id_fkey"
            columns: ["booking_id"]
            isOneToOne: false
            referencedRelation: "bookings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_progress_events_challenge_id_fkey"
            columns: ["challenge_id"]
            isOneToOne: false
            referencedRelation: "challenges"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_progress_events_instructor_id_fkey"
            columns: ["instructor_id"]
            isOneToOne: false
            referencedRelation: "instructors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_progress_events_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_progress_events_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_progress_events_occurrence_id_fkey"
            columns: ["occurrence_id"]
            isOneToOne: false
            referencedRelation: "class_occurrences"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_progress_events_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_progress_events_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      challenge_templates: {
        Row: {
          audience: Database["public"]["Enums"]["challenge_audience"]
          created_at: string
          description: string | null
          duration_days: number
          goal_value: number
          id: string
          reward_description: string | null
          studio_id: string | null
          title: string
          type: Database["public"]["Enums"]["challenge_type"]
        }
        Insert: {
          audience?: Database["public"]["Enums"]["challenge_audience"]
          created_at?: string
          description?: string | null
          duration_days: number
          goal_value: number
          id?: string
          reward_description?: string | null
          studio_id?: string | null
          title: string
          type: Database["public"]["Enums"]["challenge_type"]
        }
        Update: {
          audience?: Database["public"]["Enums"]["challenge_audience"]
          created_at?: string
          description?: string | null
          duration_days?: number
          goal_value?: number
          id?: string
          reward_description?: string | null
          studio_id?: string | null
          title?: string
          type?: Database["public"]["Enums"]["challenge_type"]
        }
        Relationships: [
          {
            foreignKeyName: "challenge_templates_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenge_templates_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      challenges: {
        Row: {
          audience: Database["public"]["Enums"]["challenge_audience"]
          auto_enrol: boolean
          class_type_ids: Json
          cover_image_url: string | null
          created_at: string
          created_by: string | null
          description: string | null
          ends_on: string
          goal_value: number
          id: string
          join_deadline: string
          reward_description: string | null
          starts_on: string
          status: Database["public"]["Enums"]["challenge_status"]
          studio_id: string
          template_id: string | null
          title: string
          type: Database["public"]["Enums"]["challenge_type"]
          updated_at: string
        }
        Insert: {
          audience?: Database["public"]["Enums"]["challenge_audience"]
          auto_enrol?: boolean
          class_type_ids?: Json
          cover_image_url?: string | null
          created_at?: string
          created_by?: string | null
          description?: string | null
          ends_on: string
          goal_value: number
          id?: string
          join_deadline: string
          reward_description?: string | null
          starts_on: string
          status?: Database["public"]["Enums"]["challenge_status"]
          studio_id: string
          template_id?: string | null
          title: string
          type: Database["public"]["Enums"]["challenge_type"]
          updated_at?: string
        }
        Update: {
          audience?: Database["public"]["Enums"]["challenge_audience"]
          auto_enrol?: boolean
          class_type_ids?: Json
          cover_image_url?: string | null
          created_at?: string
          created_by?: string | null
          description?: string | null
          ends_on?: string
          goal_value?: number
          id?: string
          join_deadline?: string
          reward_description?: string | null
          starts_on?: string
          status?: Database["public"]["Enums"]["challenge_status"]
          studio_id?: string
          template_id?: string | null
          title?: string
          type?: Database["public"]["Enums"]["challenge_type"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "challenges_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenges_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenges_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challenges_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "challenge_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      check_ins: {
        Row: {
          booking_id: string | null
          checked_in_at: string
          checked_in_by: string | null
          created_at: string
          id: string
          import_id: string | null
          is_demo: boolean
          member_id: string
          method: Database["public"]["Enums"]["checkin_method"]
          occurrence_id: string | null
          studio_id: string
        }
        Insert: {
          booking_id?: string | null
          checked_in_at?: string
          checked_in_by?: string | null
          created_at?: string
          id?: string
          import_id?: string | null
          is_demo?: boolean
          member_id: string
          method: Database["public"]["Enums"]["checkin_method"]
          occurrence_id?: string | null
          studio_id: string
        }
        Update: {
          booking_id?: string | null
          checked_in_at?: string
          checked_in_by?: string | null
          created_at?: string
          id?: string
          import_id?: string | null
          is_demo?: boolean
          member_id?: string
          method?: Database["public"]["Enums"]["checkin_method"]
          occurrence_id?: string | null
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "check_ins_booking_id_fkey"
            columns: ["booking_id"]
            isOneToOne: true
            referencedRelation: "bookings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "check_ins_checked_in_by_fkey"
            columns: ["checked_in_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "check_ins_import_id_fkey"
            columns: ["import_id"]
            isOneToOne: false
            referencedRelation: "imports"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "check_ins_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "check_ins_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "check_ins_occurrence_id_fkey"
            columns: ["occurrence_id"]
            isOneToOne: false
            referencedRelation: "class_occurrences"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "check_ins_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "check_ins_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      class_occurrences: {
        Row: {
          booked_count: number
          cancellation_reason: string | null
          cancelled_at: string | null
          capacity: number
          class_type_id: string | null
          created_at: string
          description: string | null
          ends_at: string
          id: string
          instructor_id: string | null
          instructor_notes: string | null
          is_demo: boolean
          is_exception: boolean
          location_id: string
          name: string
          room_id: string | null
          series_id: string | null
          starts_at: string
          status: Database["public"]["Enums"]["occurrence_status"]
          studio_id: string
          substitute_for: string | null
          updated_at: string
          waitlist_count: number
        }
        Insert: {
          booked_count?: number
          cancellation_reason?: string | null
          cancelled_at?: string | null
          capacity: number
          class_type_id?: string | null
          created_at?: string
          description?: string | null
          ends_at: string
          id?: string
          instructor_id?: string | null
          instructor_notes?: string | null
          is_demo?: boolean
          is_exception?: boolean
          location_id: string
          name: string
          room_id?: string | null
          series_id?: string | null
          starts_at: string
          status?: Database["public"]["Enums"]["occurrence_status"]
          studio_id: string
          substitute_for?: string | null
          updated_at?: string
          waitlist_count?: number
        }
        Update: {
          booked_count?: number
          cancellation_reason?: string | null
          cancelled_at?: string | null
          capacity?: number
          class_type_id?: string | null
          created_at?: string
          description?: string | null
          ends_at?: string
          id?: string
          instructor_id?: string | null
          instructor_notes?: string | null
          is_demo?: boolean
          is_exception?: boolean
          location_id?: string
          name?: string
          room_id?: string | null
          series_id?: string | null
          starts_at?: string
          status?: Database["public"]["Enums"]["occurrence_status"]
          studio_id?: string
          substitute_for?: string | null
          updated_at?: string
          waitlist_count?: number
        }
        Relationships: [
          {
            foreignKeyName: "class_occurrences_class_type_id_fkey"
            columns: ["class_type_id"]
            isOneToOne: false
            referencedRelation: "class_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_occurrences_instructor_id_fkey"
            columns: ["instructor_id"]
            isOneToOne: false
            referencedRelation: "instructors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_occurrences_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_occurrences_room_id_fkey"
            columns: ["room_id"]
            isOneToOne: false
            referencedRelation: "rooms"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_occurrences_series_id_fkey"
            columns: ["series_id"]
            isOneToOne: false
            referencedRelation: "class_series"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_occurrences_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_occurrences_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_occurrences_substitute_for_fkey"
            columns: ["substitute_for"]
            isOneToOne: false
            referencedRelation: "instructors"
            referencedColumns: ["id"]
          },
        ]
      }
      class_series: {
        Row: {
          booking_window_days: number | null
          capacity: number
          class_type_id: string | null
          created_at: string
          created_by: string | null
          description: string | null
          difficulty: string | null
          duration_minutes: number
          ends_on: string | null
          id: string
          instructor_id: string | null
          is_demo: boolean
          location_id: string
          name: string
          room_id: string | null
          rrule: string
          starts_on: string
          status: Database["public"]["Enums"]["series_status"]
          studio_id: string
          time_of_day: string
          updated_at: string
        }
        Insert: {
          booking_window_days?: number | null
          capacity: number
          class_type_id?: string | null
          created_at?: string
          created_by?: string | null
          description?: string | null
          difficulty?: string | null
          duration_minutes: number
          ends_on?: string | null
          id?: string
          instructor_id?: string | null
          is_demo?: boolean
          location_id: string
          name: string
          room_id?: string | null
          rrule: string
          starts_on: string
          status?: Database["public"]["Enums"]["series_status"]
          studio_id: string
          time_of_day: string
          updated_at?: string
        }
        Update: {
          booking_window_days?: number | null
          capacity?: number
          class_type_id?: string | null
          created_at?: string
          created_by?: string | null
          description?: string | null
          difficulty?: string | null
          duration_minutes?: number
          ends_on?: string | null
          id?: string
          instructor_id?: string | null
          is_demo?: boolean
          location_id?: string
          name?: string
          room_id?: string | null
          rrule?: string
          starts_on?: string
          status?: Database["public"]["Enums"]["series_status"]
          studio_id?: string
          time_of_day?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "class_series_class_type_id_fkey"
            columns: ["class_type_id"]
            isOneToOne: false
            referencedRelation: "class_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_series_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_series_instructor_id_fkey"
            columns: ["instructor_id"]
            isOneToOne: false
            referencedRelation: "instructors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_series_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_series_room_id_fkey"
            columns: ["room_id"]
            isOneToOne: false
            referencedRelation: "rooms"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_series_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_series_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      class_types: {
        Row: {
          color: string | null
          created_at: string
          default_capacity: number
          description: string | null
          difficulty: string | null
          duration_minutes: number
          id: string
          image_url: string | null
          is_demo: boolean
          name: string
          status: string
          studio_id: string
          updated_at: string
        }
        Insert: {
          color?: string | null
          created_at?: string
          default_capacity: number
          description?: string | null
          difficulty?: string | null
          duration_minutes: number
          id?: string
          image_url?: string | null
          is_demo?: boolean
          name: string
          status?: string
          studio_id: string
          updated_at?: string
        }
        Update: {
          color?: string | null
          created_at?: string
          default_capacity?: number
          description?: string | null
          difficulty?: string | null
          duration_minutes?: number
          id?: string
          image_url?: string | null
          is_demo?: boolean
          name?: string
          status?: string
          studio_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "class_types_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_types_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      credit_ledger: {
        Row: {
          actor_user_id: string | null
          balance_after: number
          booking_id: string | null
          created_at: string
          delta: number
          expires_at: string | null
          id: string
          is_demo: boolean
          member_id: string
          membership_id: string | null
          reason: Database["public"]["Enums"]["credit_reason"]
          studio_id: string
        }
        Insert: {
          actor_user_id?: string | null
          balance_after: number
          booking_id?: string | null
          created_at?: string
          delta: number
          expires_at?: string | null
          id?: string
          is_demo?: boolean
          member_id: string
          membership_id?: string | null
          reason: Database["public"]["Enums"]["credit_reason"]
          studio_id: string
        }
        Update: {
          actor_user_id?: string | null
          balance_after?: number
          booking_id?: string | null
          created_at?: string
          delta?: number
          expires_at?: string | null
          id?: string
          is_demo?: boolean
          member_id?: string
          membership_id?: string | null
          reason?: Database["public"]["Enums"]["credit_reason"]
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "credit_ledger_actor_user_id_fkey"
            columns: ["actor_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_ledger_booking_id_fkey"
            columns: ["booking_id"]
            isOneToOne: false
            referencedRelation: "bookings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_ledger_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_ledger_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_ledger_membership_id_fkey"
            columns: ["membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_ledger_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_ledger_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      gift_card_transactions: {
        Row: {
          balance_after: number
          created_at: string
          delta_cents: number
          gift_card_id: string
          id: string
          payment_id: string | null
          studio_id: string
        }
        Insert: {
          balance_after: number
          created_at?: string
          delta_cents: number
          gift_card_id: string
          id?: string
          payment_id?: string | null
          studio_id: string
        }
        Update: {
          balance_after?: number
          created_at?: string
          delta_cents?: number
          gift_card_id?: string
          id?: string
          payment_id?: string | null
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "gift_card_transactions_gift_card_id_fkey"
            columns: ["gift_card_id"]
            isOneToOne: false
            referencedRelation: "gift_cards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_card_transactions_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_card_transactions_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_card_transactions_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      gift_cards: {
        Row: {
          balance_cents: number
          code_hash: string
          code_last4: string
          created_at: string
          expires_on: string | null
          id: string
          initial_amount_cents: number
          message: string | null
          purchaser_member_id: string | null
          recipient_email: string | null
          recipient_name: string | null
          status: string
          studio_id: string
          updated_at: string
        }
        Insert: {
          balance_cents: number
          code_hash: string
          code_last4: string
          created_at?: string
          expires_on?: string | null
          id?: string
          initial_amount_cents: number
          message?: string | null
          purchaser_member_id?: string | null
          recipient_email?: string | null
          recipient_name?: string | null
          status?: string
          studio_id: string
          updated_at?: string
        }
        Update: {
          balance_cents?: number
          code_hash?: string
          code_last4?: string
          created_at?: string
          expires_on?: string | null
          id?: string
          initial_amount_cents?: number
          message?: string | null
          purchaser_member_id?: string | null
          recipient_email?: string | null
          recipient_name?: string | null
          status?: string
          studio_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "gift_cards_purchaser_member_id_fkey"
            columns: ["purchaser_member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_cards_purchaser_member_id_fkey"
            columns: ["purchaser_member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_cards_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_cards_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      import_rows: {
        Row: {
          created_at: string
          entity_id: string | null
          entity_table: string | null
          error: string | null
          id: string
          import_id: string
          normalized: Json | null
          raw: Json
          row_number: number
          status: string
        }
        Insert: {
          created_at?: string
          entity_id?: string | null
          entity_table?: string | null
          error?: string | null
          id?: string
          import_id: string
          normalized?: Json | null
          raw: Json
          row_number: number
          status?: string
        }
        Update: {
          created_at?: string
          entity_id?: string | null
          entity_table?: string | null
          error?: string | null
          id?: string
          import_id?: string
          normalized?: Json | null
          raw?: Json
          row_number?: number
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "import_rows_import_id_fkey"
            columns: ["import_id"]
            isOneToOne: false
            referencedRelation: "imports"
            referencedColumns: ["id"]
          },
        ]
      }
      imports: {
        Row: {
          created_at: string
          created_by: string | null
          error_count: number
          filename: string
          id: string
          mapping: Json
          report: Json
          row_count: number
          status: Database["public"]["Enums"]["import_status"]
          studio_id: string
          type: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          error_count?: number
          filename: string
          id?: string
          mapping?: Json
          report?: Json
          row_count?: number
          status?: Database["public"]["Enums"]["import_status"]
          studio_id: string
          type: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          error_count?: number
          filename?: string
          id?: string
          mapping?: Json
          report?: Json
          row_count?: number
          status?: Database["public"]["Enums"]["import_status"]
          studio_id?: string
          type?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "imports_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "imports_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "imports_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      insight_config: {
        Row: {
          key: string
          note: string | null
          studio_id: string | null
          updated_at: string
          value: number
        }
        Insert: {
          key: string
          note?: string | null
          studio_id?: string | null
          updated_at?: string
          value: number
        }
        Update: {
          key?: string
          note?: string | null
          studio_id?: string | null
          updated_at?: string
          value?: number
        }
        Relationships: [
          {
            foreignKeyName: "insight_config_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "insight_config_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      instructor_achievements: {
        Row: {
          acknowledged_at: string | null
          created_at: string
          definition_id: string
          earned_at: string
          id: string
          instructor_id: string
          studio_id: string
        }
        Insert: {
          acknowledged_at?: string | null
          created_at?: string
          definition_id: string
          earned_at?: string
          id?: string
          instructor_id: string
          studio_id: string
        }
        Update: {
          acknowledged_at?: string | null
          created_at?: string
          definition_id?: string
          earned_at?: string
          id?: string
          instructor_id?: string
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "instructor_achievements_definition_id_fkey"
            columns: ["definition_id"]
            isOneToOne: false
            referencedRelation: "achievement_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "instructor_achievements_instructor_id_fkey"
            columns: ["instructor_id"]
            isOneToOne: false
            referencedRelation: "instructors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "instructor_achievements_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "instructor_achievements_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      instructor_availability: {
        Row: {
          created_at: string
          created_by: string | null
          day_of_week: number | null
          effective_from: string | null
          effective_to: string | null
          ends_at_time: string | null
          exception_date: string | null
          id: string
          instructor_id: string
          is_available: boolean
          note: string | null
          starts_at_time: string | null
          studio_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          day_of_week?: number | null
          effective_from?: string | null
          effective_to?: string | null
          ends_at_time?: string | null
          exception_date?: string | null
          id?: string
          instructor_id: string
          is_available?: boolean
          note?: string | null
          starts_at_time?: string | null
          studio_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          day_of_week?: number | null
          effective_from?: string | null
          effective_to?: string | null
          ends_at_time?: string | null
          exception_date?: string | null
          id?: string
          instructor_id?: string
          is_available?: boolean
          note?: string | null
          starts_at_time?: string | null
          studio_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "instructor_availability_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "instructor_availability_instructor_id_fkey"
            columns: ["instructor_id"]
            isOneToOne: false
            referencedRelation: "instructors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "instructor_availability_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "instructor_availability_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      instructors: {
        Row: {
          avatar_url: string | null
          bio: string | null
          certifications: Json
          color: string | null
          created_at: string
          display_name: string
          id: string
          is_demo: boolean
          staff_id: string | null
          status: string
          studio_id: string
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          bio?: string | null
          certifications?: Json
          color?: string | null
          created_at?: string
          display_name: string
          id?: string
          is_demo?: boolean
          staff_id?: string | null
          status?: string
          studio_id: string
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          bio?: string | null
          certifications?: Json
          color?: string | null
          created_at?: string
          display_name?: string
          id?: string
          is_demo?: boolean
          staff_id?: string | null
          status?: string
          studio_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "instructors_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "studio_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "instructors_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "instructors_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      job_runs: {
        Row: {
          attempts: number
          error: string | null
          finished_at: string | null
          id: string
          job_key: string
          run_for: string
          started_at: string
          status: string
        }
        Insert: {
          attempts?: number
          error?: string | null
          finished_at?: string | null
          id?: string
          job_key: string
          run_for: string
          started_at?: string
          status?: string
        }
        Update: {
          attempts?: number
          error?: string | null
          finished_at?: string | null
          id?: string
          job_key?: string
          run_for?: string
          started_at?: string
          status?: string
        }
        Relationships: []
      }
      locations: {
        Row: {
          address: Json | null
          created_at: string
          id: string
          is_primary: boolean
          name: string
          status: string
          studio_id: string
          timezone: string | null
          updated_at: string
        }
        Insert: {
          address?: Json | null
          created_at?: string
          id?: string
          is_primary?: boolean
          name: string
          status?: string
          studio_id: string
          timezone?: string | null
          updated_at?: string
        }
        Update: {
          address?: Json | null
          created_at?: string
          id?: string
          is_primary?: boolean
          name?: string
          status?: string
          studio_id?: string
          timezone?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "locations_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "locations_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      member_achievements: {
        Row: {
          acknowledged_at: string | null
          created_at: string
          definition_id: string
          earned_at: string
          id: string
          member_id: string
          studio_id: string
        }
        Insert: {
          acknowledged_at?: string | null
          created_at?: string
          definition_id: string
          earned_at?: string
          id?: string
          member_id: string
          studio_id: string
        }
        Update: {
          acknowledged_at?: string | null
          created_at?: string
          definition_id?: string
          earned_at?: string
          id?: string
          member_id?: string
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "member_achievements_definition_id_fkey"
            columns: ["definition_id"]
            isOneToOne: false
            referencedRelation: "achievement_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_achievements_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_achievements_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_achievements_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_achievements_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      member_goals: {
        Row: {
          completed_at: string | null
          created_at: string
          current_value: number
          id: string
          member_id: string
          status: string
          studio_id: string
          target_date: string | null
          target_type: string
          target_value: number | null
          title: string
          updated_at: string
        }
        Insert: {
          completed_at?: string | null
          created_at?: string
          current_value?: number
          id?: string
          member_id: string
          status?: string
          studio_id: string
          target_date?: string | null
          target_type: string
          target_value?: number | null
          title: string
          updated_at?: string
        }
        Update: {
          completed_at?: string | null
          created_at?: string
          current_value?: number
          id?: string
          member_id?: string
          status?: string
          studio_id?: string
          target_date?: string | null
          target_type?: string
          target_value?: number | null
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "member_goals_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_goals_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_goals_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_goals_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      member_invites: {
        Row: {
          accepted_at: string | null
          accepted_by: string | null
          created_at: string
          created_by: string | null
          email: string
          expires_at: string
          id: string
          member_id: string
          studio_id: string
          token_hash: string
        }
        Insert: {
          accepted_at?: string | null
          accepted_by?: string | null
          created_at?: string
          created_by?: string | null
          email: string
          expires_at: string
          id?: string
          member_id: string
          studio_id: string
          token_hash: string
        }
        Update: {
          accepted_at?: string | null
          accepted_by?: string | null
          created_at?: string
          created_by?: string | null
          email?: string
          expires_at?: string
          id?: string
          member_id?: string
          studio_id?: string
          token_hash?: string
        }
        Relationships: [
          {
            foreignKeyName: "member_invites_accepted_by_fkey"
            columns: ["accepted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_invites_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_invites_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_invites_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_invites_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_invites_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      member_notes: {
        Row: {
          active: boolean
          author_user_id: string | null
          body: string
          category: Database["public"]["Enums"]["note_category"]
          created_at: string
          id: string
          managers_only: boolean
          member_id: string
          pinned: boolean
          studio_id: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          author_user_id?: string | null
          body: string
          category?: Database["public"]["Enums"]["note_category"]
          created_at?: string
          id?: string
          managers_only?: boolean
          member_id: string
          pinned?: boolean
          studio_id: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          author_user_id?: string | null
          body?: string
          category?: Database["public"]["Enums"]["note_category"]
          created_at?: string
          id?: string
          managers_only?: boolean
          member_id?: string
          pinned?: boolean
          studio_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "member_notes_author_user_id_fkey"
            columns: ["author_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_notes_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_notes_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_notes_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_notes_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      member_tag_assignments: {
        Row: {
          created_at: string
          member_id: string
          studio_id: string
          tag_id: string
        }
        Insert: {
          created_at?: string
          member_id: string
          studio_id: string
          tag_id: string
        }
        Update: {
          created_at?: string
          member_id?: string
          studio_id?: string
          tag_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "member_tag_assignments_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_tag_assignments_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_tag_assignments_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_tag_assignments_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_tag_assignments_tag_id_fkey"
            columns: ["tag_id"]
            isOneToOne: false
            referencedRelation: "member_tags"
            referencedColumns: ["id"]
          },
        ]
      }
      member_tags: {
        Row: {
          color: string | null
          created_at: string
          id: string
          name: string
          studio_id: string
        }
        Insert: {
          color?: string | null
          created_at?: string
          id?: string
          name: string
          studio_id: string
        }
        Update: {
          color?: string | null
          created_at?: string
          id?: string
          name?: string
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "member_tags_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_tags_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      members: {
        Row: {
          address: Json | null
          archived_at: string | null
          avatar_url: string | null
          created_at: string
          current_streak: number
          date_of_birth: string | null
          email: string
          emergency_contact: Json | null
          first_name: string
          first_visit_at: string | null
          health_band: string | null
          health_computed_at: string | null
          health_reason: string | null
          health_signals: Json
          id: string
          is_demo: boolean
          joined_on: string
          last_name: string
          last_visit_at: string | null
          lifetime_visits: number
          marketing_opt_in: boolean
          phone: string | null
          preferred_name: string | null
          source: string | null
          status: Database["public"]["Enums"]["member_status"]
          studio_id: string
          updated_at: string
          user_id: string | null
          waiver_signed_at: string | null
        }
        Insert: {
          address?: Json | null
          archived_at?: string | null
          avatar_url?: string | null
          created_at?: string
          current_streak?: number
          date_of_birth?: string | null
          email: string
          emergency_contact?: Json | null
          first_name: string
          first_visit_at?: string | null
          health_band?: string | null
          health_computed_at?: string | null
          health_reason?: string | null
          health_signals?: Json
          id?: string
          is_demo?: boolean
          joined_on?: string
          last_name: string
          last_visit_at?: string | null
          lifetime_visits?: number
          marketing_opt_in?: boolean
          phone?: string | null
          preferred_name?: string | null
          source?: string | null
          status?: Database["public"]["Enums"]["member_status"]
          studio_id: string
          updated_at?: string
          user_id?: string | null
          waiver_signed_at?: string | null
        }
        Update: {
          address?: Json | null
          archived_at?: string | null
          avatar_url?: string | null
          created_at?: string
          current_streak?: number
          date_of_birth?: string | null
          email?: string
          emergency_contact?: Json | null
          first_name?: string
          first_visit_at?: string | null
          health_band?: string | null
          health_computed_at?: string | null
          health_reason?: string | null
          health_signals?: Json
          id?: string
          is_demo?: boolean
          joined_on?: string
          last_name?: string
          last_visit_at?: string | null
          lifetime_visits?: number
          marketing_opt_in?: boolean
          phone?: string | null
          preferred_name?: string | null
          source?: string | null
          status?: Database["public"]["Enums"]["member_status"]
          studio_id?: string
          updated_at?: string
          user_id?: string | null
          waiver_signed_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "members_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "members_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "members_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      membership_events: {
        Row: {
          actor_user_id: string | null
          created_at: string
          effective_at: string
          from_status: Database["public"]["Enums"]["membership_status"] | null
          id: string
          membership_id: string
          metadata: Json
          studio_id: string
          to_status: Database["public"]["Enums"]["membership_status"] | null
          type: string
        }
        Insert: {
          actor_user_id?: string | null
          created_at?: string
          effective_at?: string
          from_status?: Database["public"]["Enums"]["membership_status"] | null
          id?: string
          membership_id: string
          metadata?: Json
          studio_id: string
          to_status?: Database["public"]["Enums"]["membership_status"] | null
          type: string
        }
        Update: {
          actor_user_id?: string | null
          created_at?: string
          effective_at?: string
          from_status?: Database["public"]["Enums"]["membership_status"] | null
          id?: string
          membership_id?: string
          metadata?: Json
          studio_id?: string
          to_status?: Database["public"]["Enums"]["membership_status"] | null
          type?: string
        }
        Relationships: [
          {
            foreignKeyName: "membership_events_actor_user_id_fkey"
            columns: ["actor_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "membership_events_membership_id_fkey"
            columns: ["membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "membership_events_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "membership_events_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      membership_plans: {
        Row: {
          billing_interval:
            | Database["public"]["Enums"]["billing_interval"]
            | null
          billing_interval_count: number
          booking_window_days: number | null
          cancellation_notice_days: number
          commitment_months: number
          created_at: string
          credits: number | null
          credits_per_period: number | null
          currency: string
          description: string | null
          freeze_allowed: boolean
          id: string
          is_demo: boolean
          max_bookings_per_day: number | null
          max_freeze_days: number | null
          name: string
          price_cents: number
          restrictions: Json
          signup_fee_cents: number
          sort_order: number
          status: string
          stripe_price_id: string | null
          stripe_product_id: string | null
          studio_id: string
          type: Database["public"]["Enums"]["plan_type"]
          updated_at: string
          validity_days: number | null
          visibility: string
        }
        Insert: {
          billing_interval?:
            | Database["public"]["Enums"]["billing_interval"]
            | null
          billing_interval_count?: number
          booking_window_days?: number | null
          cancellation_notice_days?: number
          commitment_months?: number
          created_at?: string
          credits?: number | null
          credits_per_period?: number | null
          currency: string
          description?: string | null
          freeze_allowed?: boolean
          id?: string
          is_demo?: boolean
          max_bookings_per_day?: number | null
          max_freeze_days?: number | null
          name: string
          price_cents: number
          restrictions?: Json
          signup_fee_cents?: number
          sort_order?: number
          status?: string
          stripe_price_id?: string | null
          stripe_product_id?: string | null
          studio_id: string
          type: Database["public"]["Enums"]["plan_type"]
          updated_at?: string
          validity_days?: number | null
          visibility?: string
        }
        Update: {
          billing_interval?:
            | Database["public"]["Enums"]["billing_interval"]
            | null
          billing_interval_count?: number
          booking_window_days?: number | null
          cancellation_notice_days?: number
          commitment_months?: number
          created_at?: string
          credits?: number | null
          credits_per_period?: number | null
          currency?: string
          description?: string | null
          freeze_allowed?: boolean
          id?: string
          is_demo?: boolean
          max_bookings_per_day?: number | null
          max_freeze_days?: number | null
          name?: string
          price_cents?: number
          restrictions?: Json
          signup_fee_cents?: number
          sort_order?: number
          status?: string
          stripe_price_id?: string | null
          stripe_product_id?: string | null
          studio_id?: string
          type?: Database["public"]["Enums"]["plan_type"]
          updated_at?: string
          validity_days?: number | null
          visibility?: string
        }
        Relationships: [
          {
            foreignKeyName: "membership_plans_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "membership_plans_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      memberships: {
        Row: {
          auto_renew: boolean
          cancel_at: string | null
          cancellation_reason: string | null
          cancelled_at: string | null
          created_at: string
          credits_remaining: number | null
          credits_reset_at: string | null
          currency: string
          current_period_end: string | null
          current_period_start: string | null
          expires_on: string | null
          freeze_days_used: number
          freeze_end: string | null
          freeze_start: string | null
          id: string
          is_demo: boolean
          member_id: string
          plan_id: string
          price_cents: number
          renews_on: string | null
          starts_on: string
          status: Database["public"]["Enums"]["membership_status"]
          stripe_customer_id: string | null
          stripe_subscription_id: string | null
          studio_id: string
          updated_at: string
        }
        Insert: {
          auto_renew?: boolean
          cancel_at?: string | null
          cancellation_reason?: string | null
          cancelled_at?: string | null
          created_at?: string
          credits_remaining?: number | null
          credits_reset_at?: string | null
          currency: string
          current_period_end?: string | null
          current_period_start?: string | null
          expires_on?: string | null
          freeze_days_used?: number
          freeze_end?: string | null
          freeze_start?: string | null
          id?: string
          is_demo?: boolean
          member_id: string
          plan_id: string
          price_cents: number
          renews_on?: string | null
          starts_on: string
          status: Database["public"]["Enums"]["membership_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          studio_id: string
          updated_at?: string
        }
        Update: {
          auto_renew?: boolean
          cancel_at?: string | null
          cancellation_reason?: string | null
          cancelled_at?: string | null
          created_at?: string
          credits_remaining?: number | null
          credits_reset_at?: string | null
          currency?: string
          current_period_end?: string | null
          current_period_start?: string | null
          expires_on?: string | null
          freeze_days_used?: number
          freeze_end?: string | null
          freeze_start?: string | null
          id?: string
          is_demo?: boolean
          member_id?: string
          plan_id?: string
          price_cents?: number
          renews_on?: string | null
          starts_on?: string
          status?: Database["public"]["Enums"]["membership_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          studio_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "memberships_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "memberships_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "memberships_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "membership_plans"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "memberships_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "memberships_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      message_templates: {
        Row: {
          body: string
          created_at: string
          id: string
          key: string
          note: string | null
          studio_id: string | null
          subject: string
          updated_at: string
        }
        Insert: {
          body: string
          created_at?: string
          id?: string
          key: string
          note?: string | null
          studio_id?: string | null
          subject: string
          updated_at?: string
        }
        Update: {
          body?: string
          created_at?: string
          id?: string
          key?: string
          note?: string | null
          studio_id?: string | null
          subject?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "message_templates_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "message_templates_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      messages: {
        Row: {
          body: string
          channel: Database["public"]["Enums"]["notif_channel"]
          created_at: string
          created_by: string | null
          error: string | null
          id: string
          member_id: string
          sent_at: string | null
          status: Database["public"]["Enums"]["message_status"]
          studio_id: string
          subject: string
          template_key: string | null
          updated_at: string
        }
        Insert: {
          body: string
          channel?: Database["public"]["Enums"]["notif_channel"]
          created_at?: string
          created_by?: string | null
          error?: string | null
          id?: string
          member_id: string
          sent_at?: string | null
          status?: Database["public"]["Enums"]["message_status"]
          studio_id: string
          subject: string
          template_key?: string | null
          updated_at?: string
        }
        Update: {
          body?: string
          channel?: Database["public"]["Enums"]["notif_channel"]
          created_at?: string
          created_by?: string | null
          error?: string | null
          id?: string
          member_id?: string
          sent_at?: string | null
          status?: Database["public"]["Enums"]["message_status"]
          studio_id?: string
          subject?: string
          template_key?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "messages_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "messages_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "messages_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "messages_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "messages_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      morning_briefs: {
        Row: {
          brief_date: string
          created_at: string
          generated_at: string
          id: string
          insight_ids: string[]
          metrics: Json
          opened_at: string | null
          studio_id: string
          summary: string
        }
        Insert: {
          brief_date: string
          created_at?: string
          generated_at?: string
          id?: string
          insight_ids?: string[]
          metrics?: Json
          opened_at?: string | null
          studio_id: string
          summary: string
        }
        Update: {
          brief_date?: string
          created_at?: string
          generated_at?: string
          id?: string
          insight_ids?: string[]
          metrics?: Json
          opened_at?: string | null
          studio_id?: string
          summary?: string
        }
        Relationships: [
          {
            foreignKeyName: "morning_briefs_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "morning_briefs_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      notification_config: {
        Row: {
          key: string
          note: string | null
          value: string
        }
        Insert: {
          key: string
          note?: string | null
          value: string
        }
        Update: {
          key?: string
          note?: string | null
          value?: string
        }
        Relationships: []
      }
      notification_preferences: {
        Row: {
          booking_email: boolean
          booking_push: boolean
          challenge_push: boolean
          created_at: string
          credit_expiry_email: boolean
          marketing_email: boolean
          member_id: string
          milestone_email: boolean
          milestone_push: boolean
          reminder_email: boolean
          reminder_push: boolean
          studio_id: string
          updated_at: string
          waitlist_email: boolean
          waitlist_push: boolean
        }
        Insert: {
          booking_email?: boolean
          booking_push?: boolean
          challenge_push?: boolean
          created_at?: string
          credit_expiry_email?: boolean
          marketing_email?: boolean
          member_id: string
          milestone_email?: boolean
          milestone_push?: boolean
          reminder_email?: boolean
          reminder_push?: boolean
          studio_id: string
          updated_at?: string
          waitlist_email?: boolean
          waitlist_push?: boolean
        }
        Update: {
          booking_email?: boolean
          booking_push?: boolean
          challenge_push?: boolean
          created_at?: string
          credit_expiry_email?: boolean
          marketing_email?: boolean
          member_id?: string
          milestone_email?: boolean
          milestone_push?: boolean
          reminder_email?: boolean
          reminder_push?: boolean
          studio_id?: string
          updated_at?: string
          waitlist_email?: boolean
          waitlist_push?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "notification_preferences_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: true
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notification_preferences_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: true
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notification_preferences_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notification_preferences_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      notification_templates: {
        Row: {
          html_body: string
          key: string
          note: string | null
          subject: string
          text_body: string
        }
        Insert: {
          html_body: string
          key: string
          note?: string | null
          subject: string
          text_body: string
        }
        Update: {
          html_body?: string
          key?: string
          note?: string | null
          subject?: string
          text_body?: string
        }
        Relationships: []
      }
      notifications: {
        Row: {
          attempts: number
          channel: Database["public"]["Enums"]["notif_channel"]
          claimed_at: string | null
          created_at: string
          dedupe_key: string
          error: string | null
          failed_at: string | null
          id: string
          member_id: string | null
          net_request_id: number | null
          payload: Json
          provider_message_id: string | null
          recipient_type: string
          scheduled_for: string
          sent_at: string | null
          status: Database["public"]["Enums"]["notif_status"]
          studio_id: string
          template_key: string
          user_id: string | null
        }
        Insert: {
          attempts?: number
          channel: Database["public"]["Enums"]["notif_channel"]
          claimed_at?: string | null
          created_at?: string
          dedupe_key: string
          error?: string | null
          failed_at?: string | null
          id?: string
          member_id?: string | null
          net_request_id?: number | null
          payload?: Json
          provider_message_id?: string | null
          recipient_type: string
          scheduled_for: string
          sent_at?: string | null
          status?: Database["public"]["Enums"]["notif_status"]
          studio_id: string
          template_key: string
          user_id?: string | null
        }
        Update: {
          attempts?: number
          channel?: Database["public"]["Enums"]["notif_channel"]
          claimed_at?: string | null
          created_at?: string
          dedupe_key?: string
          error?: string | null
          failed_at?: string | null
          id?: string
          member_id?: string | null
          net_request_id?: number | null
          payload?: Json
          provider_message_id?: string | null
          recipient_type?: string
          scheduled_for?: string
          sent_at?: string | null
          status?: Database["public"]["Enums"]["notif_status"]
          studio_id?: string
          template_key?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "notifications_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      payments: {
        Row: {
          amount_cents: number
          attempt_count: number
          booking_id: string | null
          card_brand: string | null
          card_last4: string | null
          created_at: string
          currency: string
          description: string | null
          failure_code: string | null
          failure_message: string | null
          gift_card_id: string | null
          id: string
          is_demo: boolean
          member_id: string | null
          membership_id: string | null
          next_retry_at: string | null
          paid_at: string | null
          promo_code_id: string | null
          status: Database["public"]["Enums"]["payment_status"]
          stripe_charge_id: string | null
          stripe_invoice_id: string | null
          stripe_payment_intent_id: string | null
          studio_id: string
          updated_at: string
        }
        Insert: {
          amount_cents: number
          attempt_count?: number
          booking_id?: string | null
          card_brand?: string | null
          card_last4?: string | null
          created_at?: string
          currency: string
          description?: string | null
          failure_code?: string | null
          failure_message?: string | null
          gift_card_id?: string | null
          id?: string
          is_demo?: boolean
          member_id?: string | null
          membership_id?: string | null
          next_retry_at?: string | null
          paid_at?: string | null
          promo_code_id?: string | null
          status: Database["public"]["Enums"]["payment_status"]
          stripe_charge_id?: string | null
          stripe_invoice_id?: string | null
          stripe_payment_intent_id?: string | null
          studio_id: string
          updated_at?: string
        }
        Update: {
          amount_cents?: number
          attempt_count?: number
          booking_id?: string | null
          card_brand?: string | null
          card_last4?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          failure_code?: string | null
          failure_message?: string | null
          gift_card_id?: string | null
          id?: string
          is_demo?: boolean
          member_id?: string | null
          membership_id?: string | null
          next_retry_at?: string | null
          paid_at?: string | null
          promo_code_id?: string | null
          status?: Database["public"]["Enums"]["payment_status"]
          stripe_charge_id?: string | null
          stripe_invoice_id?: string | null
          stripe_payment_intent_id?: string | null
          studio_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payments_booking_id_fkey"
            columns: ["booking_id"]
            isOneToOne: false
            referencedRelation: "bookings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_gift_card_fk"
            columns: ["gift_card_id"]
            isOneToOne: false
            referencedRelation: "gift_cards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_membership_id_fkey"
            columns: ["membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_promo_fk"
            columns: ["promo_code_id"]
            isOneToOne: false
            referencedRelation: "promo_codes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      plan_templates: {
        Row: {
          billing_interval:
            | Database["public"]["Enums"]["billing_interval"]
            | null
          billing_interval_count: number
          booking_window_days: number | null
          cancellation_notice_days: number
          commitment_months: number
          created_at: string
          credits: number | null
          credits_per_period: number | null
          description: string | null
          freeze_allowed: boolean
          id: string
          max_bookings_per_day: number | null
          max_freeze_days: number | null
          name: string
          price_cents: number | null
          restrictions: Json
          signup_fee_cents: number
          sort_order: number
          studio_id: string | null
          type: Database["public"]["Enums"]["plan_type"]
          validity_days: number | null
          visibility: string
        }
        Insert: {
          billing_interval?:
            | Database["public"]["Enums"]["billing_interval"]
            | null
          billing_interval_count?: number
          booking_window_days?: number | null
          cancellation_notice_days?: number
          commitment_months?: number
          created_at?: string
          credits?: number | null
          credits_per_period?: number | null
          description?: string | null
          freeze_allowed?: boolean
          id?: string
          max_bookings_per_day?: number | null
          max_freeze_days?: number | null
          name: string
          price_cents?: number | null
          restrictions?: Json
          signup_fee_cents?: number
          sort_order?: number
          studio_id?: string | null
          type: Database["public"]["Enums"]["plan_type"]
          validity_days?: number | null
          visibility?: string
        }
        Update: {
          billing_interval?:
            | Database["public"]["Enums"]["billing_interval"]
            | null
          billing_interval_count?: number
          booking_window_days?: number | null
          cancellation_notice_days?: number
          commitment_months?: number
          created_at?: string
          credits?: number | null
          credits_per_period?: number | null
          description?: string | null
          freeze_allowed?: boolean
          id?: string
          max_bookings_per_day?: number | null
          max_freeze_days?: number | null
          name?: string
          price_cents?: number | null
          restrictions?: Json
          signup_fee_cents?: number
          sort_order?: number
          studio_id?: string | null
          type?: Database["public"]["Enums"]["plan_type"]
          validity_days?: number | null
          visibility?: string
        }
        Relationships: [
          {
            foreignKeyName: "plan_templates_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_templates_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      platform_admins: {
        Row: {
          created_at: string
          email: string
          note: string | null
          user_id: string
        }
        Insert: {
          created_at?: string
          email: string
          note?: string | null
          user_id: string
        }
        Update: {
          created_at?: string
          email?: string
          note?: string | null
          user_id?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          avatar_url: string | null
          created_at: string
          email: string
          full_name: string | null
          id: string
          phone: string | null
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          email: string
          full_name?: string | null
          id: string
          phone?: string | null
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          email?: string
          full_name?: string | null
          id?: string
          phone?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      promo_codes: {
        Row: {
          applies_to_plans: Json
          code: string
          created_at: string
          discount_type: string
          discount_value: number
          ends_at: string | null
          id: string
          max_redemptions: number | null
          per_member_limit: number
          redemption_count: number
          starts_at: string | null
          status: string
          stripe_coupon_id: string | null
          studio_id: string
          updated_at: string
        }
        Insert: {
          applies_to_plans?: Json
          code: string
          created_at?: string
          discount_type: string
          discount_value: number
          ends_at?: string | null
          id?: string
          max_redemptions?: number | null
          per_member_limit?: number
          redemption_count?: number
          starts_at?: string | null
          status?: string
          stripe_coupon_id?: string | null
          studio_id: string
          updated_at?: string
        }
        Update: {
          applies_to_plans?: Json
          code?: string
          created_at?: string
          discount_type?: string
          discount_value?: number
          ends_at?: string | null
          id?: string
          max_redemptions?: number | null
          per_member_limit?: number
          redemption_count?: number
          starts_at?: string | null
          status?: string
          stripe_coupon_id?: string | null
          studio_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "promo_codes_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promo_codes_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      promo_redemptions: {
        Row: {
          created_at: string
          id: string
          member_id: string
          payment_id: string | null
          promo_code_id: string
          studio_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          member_id: string
          payment_id?: string | null
          promo_code_id: string
          studio_id: string
        }
        Update: {
          created_at?: string
          id?: string
          member_id?: string
          payment_id?: string | null
          promo_code_id?: string
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "promo_redemptions_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promo_redemptions_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promo_redemptions_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promo_redemptions_promo_code_id_fkey"
            columns: ["promo_code_id"]
            isOneToOne: false
            referencedRelation: "promo_codes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promo_redemptions_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promo_redemptions_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      push_subscriptions: {
        Row: {
          auth: string
          created_at: string
          endpoint: string
          id: string
          last_used_at: string | null
          member_id: string | null
          p256dh: string
          revoked_at: string | null
          studio_id: string
          user_agent: string | null
          user_id: string | null
        }
        Insert: {
          auth: string
          created_at?: string
          endpoint: string
          id?: string
          last_used_at?: string | null
          member_id?: string | null
          p256dh: string
          revoked_at?: string | null
          studio_id: string
          user_agent?: string | null
          user_id?: string | null
        }
        Update: {
          auth?: string
          created_at?: string
          endpoint?: string
          id?: string
          last_used_at?: string | null
          member_id?: string | null
          p256dh?: string
          revoked_at?: string | null
          studio_id?: string
          user_agent?: string | null
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "push_subscriptions_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "push_subscriptions_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "push_subscriptions_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "push_subscriptions_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "push_subscriptions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      refunds: {
        Row: {
          amount_cents: number
          created_at: string
          created_by: string | null
          id: string
          payment_id: string
          reason: string
          stripe_refund_id: string | null
          studio_id: string
        }
        Insert: {
          amount_cents: number
          created_at?: string
          created_by?: string | null
          id?: string
          payment_id: string
          reason: string
          stripe_refund_id?: string | null
          studio_id: string
        }
        Update: {
          amount_cents?: number
          created_at?: string
          created_by?: string | null
          id?: string
          payment_id?: string
          reason?: string
          stripe_refund_id?: string | null
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "refunds_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "refunds_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "refunds_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "refunds_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      rooms: {
        Row: {
          capacity: number
          color: string | null
          created_at: string
          id: string
          is_demo: boolean
          location_id: string
          name: string
          status: string
          studio_id: string
          updated_at: string
        }
        Insert: {
          capacity: number
          color?: string | null
          created_at?: string
          id?: string
          is_demo?: boolean
          location_id: string
          name: string
          status?: string
          studio_id: string
          updated_at?: string
        }
        Update: {
          capacity?: number
          color?: string | null
          created_at?: string
          id?: string
          is_demo?: boolean
          location_id?: string
          name?: string
          status?: string
          studio_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "rooms_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rooms_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rooms_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      stripe_config: {
        Row: {
          key: string
          note: string | null
          value: string
        }
        Insert: {
          key: string
          note?: string | null
          value: string
        }
        Update: {
          key?: string
          note?: string | null
          value?: string
        }
        Relationships: []
      }
      stripe_events: {
        Row: {
          created_at: string
          error: string | null
          id: string
          payload: Json
          processed_at: string | null
          stripe_account_id: string | null
          studio_id: string | null
          type: string
        }
        Insert: {
          created_at?: string
          error?: string | null
          id: string
          payload: Json
          processed_at?: string | null
          stripe_account_id?: string | null
          studio_id?: string | null
          type: string
        }
        Update: {
          created_at?: string
          error?: string | null
          id?: string
          payload?: Json
          processed_at?: string | null
          stripe_account_id?: string | null
          studio_id?: string | null
          type?: string
        }
        Relationships: [
          {
            foreignKeyName: "stripe_events_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stripe_events_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      stripe_oauth_states: {
        Row: {
          created_at: string
          created_by: string | null
          expires_at: string
          state: string
          studio_id: string
          used_at: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          expires_at?: string
          state: string
          studio_id: string
          used_at?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          expires_at?: string
          state?: string
          studio_id?: string
          used_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "stripe_oauth_states_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stripe_oauth_states_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stripe_oauth_states_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      studio_invites: {
        Row: {
          accepted_at: string | null
          accepted_by: string | null
          created_at: string
          created_by: string | null
          email: string
          expires_at: string
          id: string
          studio_id: string
          token_hash: string
        }
        Insert: {
          accepted_at?: string | null
          accepted_by?: string | null
          created_at?: string
          created_by?: string | null
          email: string
          expires_at: string
          id?: string
          studio_id: string
          token_hash: string
        }
        Update: {
          accepted_at?: string | null
          accepted_by?: string | null
          created_at?: string
          created_by?: string | null
          email?: string
          expires_at?: string
          id?: string
          studio_id?: string
          token_hash?: string
        }
        Relationships: [
          {
            foreignKeyName: "studio_invites_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "studio_invites_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      studio_settings: {
        Row: {
          booking_cutoff_minutes: number
          booking_window_days: number
          cancellation_cutoff_minutes: number
          checkin_closes_minutes_after: number
          checkin_opens_minutes_before: number
          checkin_secret: string
          checkin_window_enforced: boolean
          created_at: string
          dropin_payment_window_minutes: number
          late_cancel_consumes_credit: boolean
          late_cancel_fee_cents: number
          max_bookings_per_day: number | null
          max_future_bookings: number | null
          morning_brief_send_at: string
          no_show_consumes_credit: boolean
          no_show_fee_cents: number
          onboarding_completed_at: string | null
          payment_grace_days: number
          reminder_hours_before: number
          require_waiver: boolean
          setup_progress: Json
          studio_id: string
          sub_late_free_cancel: boolean
          updated_at: string
          waitlist_cutoff_minutes: number
          waitlist_enabled: boolean
          waitlist_offer_window_minutes: number
          waiver_text: string | null
          week_starts_on: number
        }
        Insert: {
          booking_cutoff_minutes?: number
          booking_window_days?: number
          cancellation_cutoff_minutes?: number
          checkin_closes_minutes_after?: number
          checkin_opens_minutes_before?: number
          checkin_secret?: string
          checkin_window_enforced?: boolean
          created_at?: string
          dropin_payment_window_minutes?: number
          late_cancel_consumes_credit?: boolean
          late_cancel_fee_cents?: number
          max_bookings_per_day?: number | null
          max_future_bookings?: number | null
          morning_brief_send_at?: string
          no_show_consumes_credit?: boolean
          no_show_fee_cents?: number
          onboarding_completed_at?: string | null
          payment_grace_days?: number
          reminder_hours_before?: number
          require_waiver?: boolean
          setup_progress?: Json
          studio_id: string
          sub_late_free_cancel?: boolean
          updated_at?: string
          waitlist_cutoff_minutes?: number
          waitlist_enabled?: boolean
          waitlist_offer_window_minutes?: number
          waiver_text?: string | null
          week_starts_on?: number
        }
        Update: {
          booking_cutoff_minutes?: number
          booking_window_days?: number
          cancellation_cutoff_minutes?: number
          checkin_closes_minutes_after?: number
          checkin_opens_minutes_before?: number
          checkin_secret?: string
          checkin_window_enforced?: boolean
          created_at?: string
          dropin_payment_window_minutes?: number
          late_cancel_consumes_credit?: boolean
          late_cancel_fee_cents?: number
          max_bookings_per_day?: number | null
          max_future_bookings?: number | null
          morning_brief_send_at?: string
          no_show_consumes_credit?: boolean
          no_show_fee_cents?: number
          onboarding_completed_at?: string | null
          payment_grace_days?: number
          reminder_hours_before?: number
          require_waiver?: boolean
          setup_progress?: Json
          studio_id?: string
          sub_late_free_cancel?: boolean
          updated_at?: string
          waitlist_cutoff_minutes?: number
          waitlist_enabled?: boolean
          waitlist_offer_window_minutes?: number
          waiver_text?: string | null
          week_starts_on?: number
        }
        Relationships: [
          {
            foreignKeyName: "studio_settings_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: true
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "studio_settings_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: true
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      studio_staff: {
        Row: {
          created_at: string
          email: string
          id: string
          invited_at: string | null
          joined_at: string | null
          role: Database["public"]["Enums"]["staff_role"]
          status: string
          studio_id: string
          updated_at: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          email: string
          id?: string
          invited_at?: string | null
          joined_at?: string | null
          role: Database["public"]["Enums"]["staff_role"]
          status?: string
          studio_id: string
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          email?: string
          id?: string
          invited_at?: string | null
          joined_at?: string | null
          role?: Database["public"]["Enums"]["staff_role"]
          status?: string
          studio_id?: string
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "studio_staff_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "studio_staff_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "studio_staff_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      studios: {
        Row: {
          accent_color: string | null
          archived_at: string | null
          brand_color: string | null
          contact_email: string | null
          contact_phone: string | null
          country: string | null
          created_at: string
          currency: string
          custom_domain: string | null
          id: string
          login_image_url: string | null
          logo_url: string | null
          name: string
          slug: string
          status: string
          stripe_account_id: string | null
          theme_preset: Database["public"]["Enums"]["theme_preset"]
          timezone: string
          updated_at: string
        }
        Insert: {
          accent_color?: string | null
          archived_at?: string | null
          brand_color?: string | null
          contact_email?: string | null
          contact_phone?: string | null
          country?: string | null
          created_at?: string
          currency: string
          custom_domain?: string | null
          id?: string
          login_image_url?: string | null
          logo_url?: string | null
          name: string
          slug: string
          status?: string
          stripe_account_id?: string | null
          theme_preset?: Database["public"]["Enums"]["theme_preset"]
          timezone: string
          updated_at?: string
        }
        Update: {
          accent_color?: string | null
          archived_at?: string | null
          brand_color?: string | null
          contact_email?: string | null
          contact_phone?: string | null
          country?: string | null
          created_at?: string
          currency?: string
          custom_domain?: string | null
          id?: string
          login_image_url?: string | null
          logo_url?: string | null
          name?: string
          slug?: string
          status?: string
          stripe_account_id?: string | null
          theme_preset?: Database["public"]["Enums"]["theme_preset"]
          timezone?: string
          updated_at?: string
        }
        Relationships: []
      }
      timeline_events: {
        Row: {
          actor_user_id: string | null
          created_at: string
          description: string | null
          id: string
          member_id: string
          metadata: Json
          occurred_at: string
          ref_id: string | null
          ref_table: string | null
          studio_id: string
          title: string
          type: string
        }
        Insert: {
          actor_user_id?: string | null
          created_at?: string
          description?: string | null
          id?: string
          member_id: string
          metadata?: Json
          occurred_at: string
          ref_id?: string | null
          ref_table?: string | null
          studio_id: string
          title: string
          type: string
        }
        Update: {
          actor_user_id?: string | null
          created_at?: string
          description?: string | null
          id?: string
          member_id?: string
          metadata?: Json
          occurred_at?: string
          ref_id?: string | null
          ref_table?: string | null
          studio_id?: string
          title?: string
          type?: string
        }
        Relationships: [
          {
            foreignKeyName: "timeline_events_actor_user_id_fkey"
            columns: ["actor_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "timeline_events_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "member_quick_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "timeline_events_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "timeline_events_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "timeline_events_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      waitlist_offers: {
        Row: {
          booking_id: string
          created_at: string
          expires_at: string
          id: string
          occurrence_id: string
          offered_at: string
          outcome: string | null
          responded_at: string | null
          studio_id: string
        }
        Insert: {
          booking_id: string
          created_at?: string
          expires_at: string
          id?: string
          occurrence_id: string
          offered_at?: string
          outcome?: string | null
          responded_at?: string | null
          studio_id: string
        }
        Update: {
          booking_id?: string
          created_at?: string
          expires_at?: string
          id?: string
          occurrence_id?: string
          offered_at?: string
          outcome?: string | null
          responded_at?: string | null
          studio_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "waitlist_offers_booking_id_fkey"
            columns: ["booking_id"]
            isOneToOne: false
            referencedRelation: "bookings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "waitlist_offers_occurrence_id_fkey"
            columns: ["occurrence_id"]
            isOneToOne: false
            referencedRelation: "class_occurrences"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "waitlist_offers_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "waitlist_offers_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      member_quick_view: {
        Row: {
          avatar_url: string | null
          current_streak: number | null
          date_of_birth: string | null
          first_name: string | null
          first_visit_at: string | null
          id: string | null
          joined_on: string | null
          last_name: string | null
          last_visit_at: string | null
          lifetime_visits: number | null
          status: Database["public"]["Enums"]["member_status"] | null
          studio_id: string | null
        }
        Insert: {
          avatar_url?: string | null
          current_streak?: number | null
          date_of_birth?: string | null
          first_name?: string | null
          first_visit_at?: string | null
          id?: string | null
          joined_on?: string | null
          last_name?: string | null
          last_visit_at?: string | null
          lifetime_visits?: number | null
          status?: Database["public"]["Enums"]["member_status"] | null
          studio_id?: string | null
        }
        Update: {
          avatar_url?: string | null
          current_streak?: number | null
          date_of_birth?: string | null
          first_name?: string | null
          first_visit_at?: string | null
          id?: string | null
          joined_on?: string | null
          last_name?: string | null
          last_visit_at?: string | null
          lifetime_visits?: number | null
          status?: Database["public"]["Enums"]["member_status"] | null
          studio_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "members_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studio_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "members_studio_id_fkey"
            columns: ["studio_id"]
            isOneToOne: false
            referencedRelation: "studios"
            referencedColumns: ["id"]
          },
        ]
      }
      studio_public: {
        Row: {
          brand_color: string | null
          country: string | null
          currency: string | null
          custom_domain: string | null
          id: string | null
          logo_url: string | null
          name: string | null
          slug: string | null
          status: string | null
          timezone: string | null
        }
        Insert: {
          brand_color?: string | null
          country?: string | null
          currency?: string | null
          custom_domain?: string | null
          id?: string | null
          logo_url?: string | null
          name?: string | null
          slug?: string | null
          status?: string | null
          timezone?: string | null
        }
        Update: {
          brand_color?: string | null
          country?: string | null
          currency?: string | null
          custom_domain?: string | null
          id?: string | null
          logo_url?: string | null
          name?: string | null
          slug?: string | null
          status?: string | null
          timezone?: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      accept_studio_invite: {
        Args: { p_full_name: string; p_password: string; p_token: string }
        Returns: Database["public"]["CompositeTypes"]["invite_acceptance"]
        SetofOptions: {
          from: "*"
          to: "invite_acceptance"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      auth_instructor_id: { Args: { target: string }; Returns: string }
      auth_member_studios: { Args: never; Returns: string[] }
      auth_role_in: {
        Args: { target: string }
        Returns: Database["public"]["Enums"]["staff_role"]
      }
      auth_staff_studios: { Args: never; Returns: string[] }
      begin_stripe_connect: { Args: { p_studio_id: string }; Returns: string }
      book_class: {
        Args: {
          p_member_id: string
          p_occurrence_id: string
          p_override_reason?: string
          p_payment_source?: Database["public"]["Enums"]["payment_source"]
          p_source: Database["public"]["Enums"]["booking_source"]
        }
        Returns: Database["public"]["CompositeTypes"]["book_class_result"]
        SetofOptions: {
          from: "*"
          to: "book_class_result"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      book_class_status_ok: {
        Args: { p_status: Database["public"]["Enums"]["member_status"] }
        Returns: boolean
      }
      brief_summary: {
        Args: { p_date: string; p_studio_id: string }
        Returns: string
      }
      cancel_booking: {
        Args: { p_booking_id: string }
        Returns: Database["public"]["CompositeTypes"]["cancel_result"]
        SetofOptions: {
          from: "*"
          to: "cancel_result"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      checkin_code_for: {
        Args: { p_bucket: number; p_member_id: string }
        Returns: string
      }
      claim_member_account: {
        Args: { p_full_name?: string; p_password: string; p_token: string }
        Returns: Database["public"]["CompositeTypes"]["member_claim"]
        SetofOptions: {
          from: "*"
          to: "member_claim"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      claim_member_by_email: {
        Args: { p_studio_id: string }
        Returns: Database["public"]["CompositeTypes"]["member_claim"]
        SetofOptions: {
          from: "*"
          to: "member_claim"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      complete_stripe_connect: {
        Args: { p_account_id: string; p_state: string }
        Returns: string
      }
      create_member_invite: {
        Args: { p_days?: number; p_member_id: string }
        Returns: {
          email: string
          expires_at: string
          token: string
        }[]
      }
      deliver_notification: {
        Args: { p_notification_id: string }
        Returns: number
      }
      dismiss_setup_item: {
        Args: { p_dismissed?: boolean; p_key: string; p_studio_id: string }
        Returns: boolean
      }
      expect: {
        Args: { actual: number; label: string; want: number }
        Returns: undefined
      }
      expect_checkin: {
        Args: {
          label: string
          p_at: string
          p_booking: string
          p_member: string
          p_occ: string
          p_studio: string
          want_ok: boolean
        }
        Returns: undefined
      }
      expect_like: {
        Args: { actual: string; label: string; pattern: string }
        Returns: undefined
      }
      expect_num: {
        Args: { actual: number; label: string; want: number }
        Returns: undefined
      }
      expect_text: {
        Args: { actual: string; label: string; want: string }
        Returns: undefined
      }
      expect_write: {
        Args: { label: string; sql: string; want_ok: boolean }
        Returns: undefined
      }
      generate_demo_data: { Args: { p_studio_id: string }; Returns: Json }
      generate_morning_brief: {
        Args: { p_for_date?: string; p_studio_id: string }
        Returns: Json
      }
      import_commit: { Args: { p_import_id: string }; Returns: Json }
      import_dry_run: { Args: { p_import_id: string }; Returns: Json }
      import_member_status: {
        Args: { p: string }
        Returns: Database["public"]["Enums"]["member_status"]
      }
      import_membership_status: {
        Args: { p: string }
        Returns: Database["public"]["Enums"]["membership_status"]
      }
      import_rollback: { Args: { p_import_id: string }; Returns: Json }
      insight_threshold: {
        Args: { p_key: string; p_studio_id: string }
        Returns: number
      }
      is_desk_up: { Args: { target: string }; Returns: boolean }
      is_manager_up: { Args: { target: string }; Returns: boolean }
      is_owner: { Args: { target: string }; Returns: boolean }
      is_platform_admin: { Args: never; Returns: boolean }
      is_service_context: { Args: never; Returns: boolean }
      login: { Args: { uid: string }; Returns: undefined }
      mark_stripe_stub_done: { Args: { p_studio_id: string }; Returns: boolean }
      member_checkin_code: {
        Args: never
        Returns: {
          code: string
          member_name: string
          seconds_left: number
        }[]
      }
      member_health: { Args: { p_member_id: string }; Returns: Json }
      member_invite_preview: {
        Args: { p_token: string }
        Returns: {
          email: string
          first_name: string
          studio_name: string
          studio_slug: string
          valid: boolean
        }[]
      }
      message_draft_for: { Args: { p_member_id: string }; Returns: Json }
      message_gap_phrase: { Args: { p_days: number }; Returns: string }
      milestone_visit_targets: { Args: never; Returns: number[] }
      notification_api_key: { Args: never; Returns: string }
      notification_setting: { Args: { p_key: string }; Returns: string }
      notification_wanted: {
        Args: { p_member_id: string; p_template: string }
        Returns: boolean
      }
      provision_studio: {
        Args: {
          p_country: string
          p_currency: string
          p_name: string
          p_owner_email: string
          p_slug: string
          p_timezone: string
          p_valid_days?: number
        }
        Returns: Database["public"]["CompositeTypes"]["provision_result"]
        SetofOptions: {
          from: "*"
          to: "provision_result"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      purge_demo_data: { Args: { p_studio_id: string }; Returns: Json }
      queue_all_credit_expiries: { Args: never; Returns: Json }
      queue_booking_notifications: {
        Args: { p_booking_id: string }
        Returns: number
      }
      queue_credit_expiries: { Args: { p_studio_id: string }; Returns: number }
      queue_milestone: {
        Args: { p_body: string; p_member_id: string; p_name: string }
        Returns: number
      }
      queue_notification: {
        Args: {
          p_dedupe_key: string
          p_member_id: string
          p_payload: Json
          p_scheduled_for?: string
          p_studio_id: string
          p_template_key: string
        }
        Returns: string
      }
      queue_occurrence_cancelled: {
        Args: { p_occurrence_id: string }
        Returns: number
      }
      queue_payment_failed: {
        Args: { p_membership_id: string }
        Returns: number
      }
      queue_substitution: {
        Args: { p_new: string; p_occurrence_id: string; p_old: string }
        Returns: number
      }
      queue_waitlist_offer: { Args: { p_offer_id: string }; Returns: number }
      rebuild_member_timeline: {
        Args: { p_member_id: string }
        Returns: number
      }
      rebuild_studio_timeline: {
        Args: { p_studio_id: string }
        Returns: number
      }
      recompute_member_stats: {
        Args: { p_member_ids?: string[]; p_studio_id: string }
        Returns: number
      }
      reconcile_notification_sends: { Args: never; Returns: Json }
      refresh_member_health: { Args: { p_member_id: string }; Returns: Json }
      refresh_studio_health: { Args: { p_studio_id: string }; Returns: number }
      render_notification: {
        Args: { p_notification_id: string }
        Returns: {
          from_name: string
          html_body: string
          reply_to: string
          subject: string
          text_body: string
          to_email: string
        }[]
      }
      resolve_checkin_code: {
        Args: { p_code: string }
        Returns: {
          email: string
          first_name: string
          last_name: string
          member_id: string
        }[]
      }
      respond_to_offer: {
        Args: { p_accept: boolean; p_offer_id: string }
        Returns: Json
      }
      run_due_morning_briefs: { Args: never; Returns: Json }
      say_count: { Args: { n: number }; Returns: string }
      send_due_notifications: { Args: never; Returns: Json }
      send_message: {
        Args: { p_message_id: string }
        Returns: {
          body: string
          channel: Database["public"]["Enums"]["notif_channel"]
          created_at: string
          created_by: string | null
          error: string | null
          id: string
          member_id: string
          sent_at: string | null
          status: Database["public"]["Enums"]["message_status"]
          studio_id: string
          subject: string
          template_key: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "messages"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      send_via_resend: {
        Args: {
          p_from_name: string
          p_html: string
          p_reply_to: string
          p_subject: string
          p_text: string
          p_to: string
        }
        Returns: number
      }
      set_insight_status: {
        Args: {
          p_insight_id: string
          p_status: Database["public"]["Enums"]["insight_status"]
        }
        Returns: {
          action_payload: Json
          action_type: string
          actioned_at: string | null
          actioned_by: string | null
          created_at: string
          dismissed_at: string | null
          estimated_impact_cents: number | null
          for_date: string
          id: string
          input_snapshot: Json | null
          model: string | null
          observation: string
          prompt_version: string | null
          recommended_action: string
          severity: string
          status: Database["public"]["Enums"]["insight_status"]
          studio_id: string
          subject_id: string | null
          subject_type: string | null
          title: string
          type: string
          updated_at: string
          why_it_matters: string
        }
        SetofOptions: {
          from: "*"
          to: "ai_insights"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      sig: { Args: { body: string; secret?: string }; Returns: string }
      stripe_handle_charge_refunded: {
        Args: { p_obj: Json; p_studio_id: string }
        Returns: string
      }
      stripe_handle_checkout_completed: {
        Args: { p_obj: Json; p_studio_id: string }
        Returns: string
      }
      stripe_handle_invoice_failed: {
        Args: { p_obj: Json; p_studio_id: string }
        Returns: string
      }
      stripe_handle_invoice_paid: {
        Args: { p_obj: Json; p_studio_id: string }
        Returns: string
      }
      stripe_handle_subscription_changed: {
        Args: { p_deleted: boolean; p_obj: Json; p_studio_id: string }
        Returns: string
      }
      stripe_secret: { Args: { p_name?: string }; Returns: string }
      stripe_setting: { Args: { p_key: string }; Returns: string }
      stripe_webhook: {
        Args: { p_payload: string; p_signature: string }
        Returns: Json
      }
      studio_by_slug: {
        Args: { p_slug: string }
        Returns: {
          accent_color: string
          currency: string
          id: string
          login_image_url: string
          logo_url: string
          name: string
          slug: string
          theme_preset: Database["public"]["Enums"]["theme_preset"]
          timezone: string
        }[]
      }
      studio_invite_preview: {
        Args: { p_token: string }
        Returns: Database["public"]["CompositeTypes"]["invite_preview"]
        SetofOptions: {
          from: "*"
          to: "invite_preview"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      studio_member_settings: {
        Args: { p_studio_id: string }
        Returns: {
          booking_cutoff_minutes: number
          cancellation_cutoff_minutes: number
          checkin_closes_minutes_after: number
          checkin_opens_minutes_before: number
          waitlist_enabled: boolean
          week_starts_on: number
        }[]
      }
      studio_setup_state: { Args: { p_studio_id: string }; Returns: Json }
      studios_due_for_brief: {
        Args: { p_now?: string }
        Returns: {
          local_date: string
          studio_id: string
        }[]
      }
      sweep_unpaid_dropins: { Args: never; Returns: Json }
      verify_stripe_signature: {
        Args: { p_payload: string; p_secret: string; p_signature: string }
        Returns: boolean
      }
    }
    Enums: {
      billing_interval: "week" | "month" | "quarter" | "year"
      booking_source: "member" | "staff" | "front_desk" | "import"
      booking_status:
        | "booked"
        | "waitlisted"
        | "cancelled"
        | "late_cancelled"
        | "attended"
        | "no_show"
        | "pending_payment"
      challenge_audience: "member" | "instructor"
      challenge_status: "draft" | "scheduled" | "active" | "ended" | "archived"
      challenge_type: "class_count" | "streak" | "class_type_count"
      checkin_method: "qr" | "staff" | "kiosk" | "self"
      credit_reason:
        | "purchase"
        | "booking"
        | "cancellation_refund"
        | "expiry"
        | "freeze_adjustment"
        | "manual"
      import_status:
        | "uploaded"
        | "validating"
        | "dry_run_complete"
        | "importing"
        | "complete"
        | "failed"
        | "rolled_back"
      insight_status: "new" | "actioned" | "dismissed" | "expired"
      member_status: "lead" | "active" | "inactive" | "archived"
      membership_status:
        | "trialing"
        | "active"
        | "past_due"
        | "frozen"
        | "cancelled"
        | "expired"
      message_status: "draft" | "queued" | "sent" | "failed"
      note_category: "general" | "injury" | "medical" | "preference" | "admin"
      notif_channel: "email" | "push" | "in_app"
      notif_status:
        | "scheduled"
        | "sending"
        | "sent"
        | "delivered"
        | "failed"
        | "cancelled"
      occurrence_status: "scheduled" | "cancelled" | "completed"
      payment_source:
        | "membership"
        | "class_pack"
        | "drop_in"
        | "comp"
        | "gift_card"
      payment_status:
        | "pending"
        | "succeeded"
        | "failed"
        | "refunded"
        | "partially_refunded"
      plan_type: "recurring" | "class_pack" | "drop_in" | "trial"
      series_status: "active" | "ended" | "cancelled"
      staff_role: "owner" | "manager" | "instructor" | "front_desk"
      theme_preset: "warm" | "clean" | "calm" | "bold"
    }
    CompositeTypes: {
      book_class_result: {
        booking_id: string | null
        status: Database["public"]["Enums"]["booking_status"] | null
        payment_source: Database["public"]["Enums"]["payment_source"] | null
        waitlist_position: number | null
        failure_reason: string | null
      }
      cancel_result: {
        status: Database["public"]["Enums"]["booking_status"] | null
        credit_returned: boolean | null
        reason: string | null
        offer_made: boolean | null
      }
      invite_acceptance: {
        user_id: string | null
        studio_id: string | null
        studio_slug: string | null
        email: string | null
        failure_reason: string | null
      }
      invite_preview: {
        studio_name: string | null
        email: string | null
        expires_at: string | null
        state: string | null
      }
      member_claim: {
        user_id: string | null
        member_id: string | null
        studio_slug: string | null
        email: string | null
        failure_reason: string | null
      }
      provision_result: {
        studio_id: string | null
        invite_token: string | null
        expires_at: string | null
        failure_reason: string | null
      }
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      billing_interval: ["week", "month", "quarter", "year"],
      booking_source: ["member", "staff", "front_desk", "import"],
      booking_status: [
        "booked",
        "waitlisted",
        "cancelled",
        "late_cancelled",
        "attended",
        "no_show",
        "pending_payment",
      ],
      challenge_audience: ["member", "instructor"],
      challenge_status: ["draft", "scheduled", "active", "ended", "archived"],
      challenge_type: ["class_count", "streak", "class_type_count"],
      checkin_method: ["qr", "staff", "kiosk", "self"],
      credit_reason: [
        "purchase",
        "booking",
        "cancellation_refund",
        "expiry",
        "freeze_adjustment",
        "manual",
      ],
      import_status: [
        "uploaded",
        "validating",
        "dry_run_complete",
        "importing",
        "complete",
        "failed",
        "rolled_back",
      ],
      insight_status: ["new", "actioned", "dismissed", "expired"],
      member_status: ["lead", "active", "inactive", "archived"],
      membership_status: [
        "trialing",
        "active",
        "past_due",
        "frozen",
        "cancelled",
        "expired",
      ],
      message_status: ["draft", "queued", "sent", "failed"],
      note_category: ["general", "injury", "medical", "preference", "admin"],
      notif_channel: ["email", "push", "in_app"],
      notif_status: [
        "scheduled",
        "sending",
        "sent",
        "delivered",
        "failed",
        "cancelled",
      ],
      occurrence_status: ["scheduled", "cancelled", "completed"],
      payment_source: [
        "membership",
        "class_pack",
        "drop_in",
        "comp",
        "gift_card",
      ],
      payment_status: [
        "pending",
        "succeeded",
        "failed",
        "refunded",
        "partially_refunded",
      ],
      plan_type: ["recurring", "class_pack", "drop_in", "trial"],
      series_status: ["active", "ended", "cancelled"],
      staff_role: ["owner", "manager", "instructor", "front_desk"],
      theme_preset: ["warm", "clean", "calm", "bold"],
    },
  },
} as const

