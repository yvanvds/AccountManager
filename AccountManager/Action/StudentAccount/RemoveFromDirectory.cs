﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class RemoveFromDirectory : AccountAction
    {
        public RemoveFromDirectory() : base(
            "Verwijder Active Directory Account",
            "Dit account bestaat enkel in Active Directory. Waarschijnlijk kan het verwijderd worden.",
            true)
        {

        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            bool connected = await State.App.Instance.AD.Connect().ConfigureAwait(false);
            if (!connected) return;
            await AccountApi.Directory.AccountManager.DeleteStudent(linkedAccount.Directory.Account).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!account.Wisa.Exists && account.Directory.Exists)
            {
                account.Actions.Add(new RemoveFromDirectory());
            }
        }
    }
}
