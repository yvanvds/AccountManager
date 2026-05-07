using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    class NoActionNeeded : GroupAction
    {
        public NoActionNeeded() : base(
            "Geen Actie Nodig",
            "Deze groepen zijn in sync. Het is niet nodig om ze aan te passen.",
            false)
        { }

        public override Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }
    }
}
