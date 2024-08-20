﻿using AccountManager.Action.Group;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Linked
{
    public class LinkedGroup
    {
        public GroupStatus<AccountApi.Wisa.ClassGroup> Wisa { get; } = new GroupStatus<AccountApi.Wisa.ClassGroup>();
        public GroupStatus<AccountApi.Smartschool.Group> Smartschool { get; } = new GroupStatus<AccountApi.Smartschool.Group>();

        public List<GroupAction> Actions { get; } = new List<GroupAction>();

        public LinkedGroup(AccountApi.Wisa.ClassGroup group)
        {
            Wisa.Group = group;
        }

        public LinkedGroup(AccountApi.Smartschool.Group group)
        {
            Smartschool.Group = group;
        }

        public string Name
        {
            get
            {
                if (Wisa.Group != null)
                {
                    var result = Wisa.Group.Name;
                    if (Wisa.Group.GroupName != "00") result += " " + Wisa.Group.GroupName;
                    return result;
                }
                if (Smartschool.Group != null) return Smartschool.Group.Name;
                return "Group Name Error";
            }
        }

        public bool OK { get; set; }

        public void SetBasicFlags()
        {
            Wisa.SetFlag();
            Smartschool.SetFlag();
        }
    }
}
